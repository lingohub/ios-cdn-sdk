//
//  LocalizationCacheManager.swift
//
//  Created by Manfred Baldauf on 31.03.25.
//

import Foundation

/// Thread-safe store for the localization state the SDK shares with the swizzled
/// `Bundle.localizedString(forKey:value:table:)` implementation.
///
/// `NSLocalizedString` can be called from any thread, so everything in here must be
/// safe to access without main-actor isolation: mutable state is protected by a lock,
/// and the remaining facts come from `UserDefaults` and `FileManager`, which are
/// thread-safe by contract.
final class LocalizationCacheManager: @unchecked Sendable {

    static let shared = LocalizationCacheManager()

    private let lock = NSLock()

    // Internal cache for loaded strings [Language: [TableName: [Key: Value]]]
    private var localizationCache: [String: [String: [String: String]]] = [:]
    // Bumped on every clearCache() so in-flight table loads from a previous
    // bundle can't be written back into the freshly cleared cache.
    private var cacheGeneration: UInt64 = 0
    private var _language: String?
    private var _swizzledBundlePaths: [String] = []

    init() {}

    // MARK: - Shared state

    /// The language override (or system language) the SDK currently uses.
    var language: String? {
        get { lock.lh_withLock { _language } }
        set { lock.lh_withLock { _language = newValue } }
    }

    /// Bundle paths registered for swizzling.
    var swizzledBundlePaths: [String] {
        get { lock.lh_withLock { _swizzledBundlePaths } }
        set { lock.lh_withLock { _swizzledBundlePaths = newValue } }
    }

    func isSwizzled(bundlePath: String) -> Bool {
        return lock.lh_withLock { _swizzledBundlePaths.contains(bundlePath) }
    }

    // MARK: - Update bundle facts (UserDefaults + FileManager, thread-safe)

    var distributionVersion: String? {
        return UserDefaults.standard.string(forKey: LingohubConstants.distributionVersion)
    }

    var updateAppVersion: String? {
        return UserDefaults.standard.string(forKey: LingohubConstants.appVersion)
    }

    /// Whether a downloaded update bundle is present and should be used for lookups.
    var isUpdateActive: Bool {
        return distributionVersion != nil && updateAppVersion != nil && updateBundleExists
    }

    // MARK: - Cache Management

    /// Retrieves a string from the custom cache, loading the necessary .strings file if needed.
    /// - Parameters:
    ///   - key: The localization key.
    ///   - tableName: The name of the .strings file (without extension, defaults to "Localizable").
    ///   - language: The ISO language code (e.g., "en", "de").
    /// - Returns: The localized string, or nil if not found.
    func getString(forKey key: String, tableName: String?, language inputLanguage: String?) -> String? {
        guard isUpdateActive else {
            // No update bundle in use, skip the custom cache.
            return nil
        }

        // Determine the language and table name to use
        let effectiveLanguage = inputLanguage ?? language ?? Locale.lingohubLanguageCode ?? "en"
        let effectiveTableName = tableName ?? "Localizable" // Default table name

        LingohubLogger.shared.log("Cache Manager: Attempting get string '\(key)' table '\(effectiveTableName)' lang '\(effectiveLanguage)'")

        // 1. Check the cache. `nil` table entry means the table was never loaded;
        //    a present table with a missing key means the key doesn't exist.
        var tableWasLoaded = false
        var generation: UInt64 = 0
        let cachedString: String? = lock.lh_withLock {
            generation = cacheGeneration
            if let table = localizationCache[effectiveLanguage]?[effectiveTableName] {
                tableWasLoaded = true
                return table[key]
            }
            return nil
        }

        if let cachedString = cachedString {
            LingohubLogger.shared.log("Cache Manager: Hit for key '\(key)'")
            return cachedString
        }
        if tableWasLoaded {
            LingohubLogger.shared.log("Cache Manager: Table '\(effectiveTableName)' lang '\(effectiveLanguage)' loaded previously, but key '\(key)' missing.")
            return nil
        }

        // 2. Load the .strings file for the language and table from the update bundle.
        //    Loading happens outside the lock; concurrent loads are idempotent.
        LingohubLogger.shared.log("Cache Manager: Miss for table '\(effectiveTableName)' lang '\(effectiveLanguage)'. Attempting to load.")
        let loadedTable = loadStringsTable(tableName: effectiveTableName, language: effectiveLanguage)

        lock.lh_withLock {
            // Only store the table if the cache wasn't cleared while we were loading,
            // otherwise a table read from the previous bundle would survive the clear.
            if generation == cacheGeneration {
                localizationCache[effectiveLanguage, default: [:]][effectiveTableName] = loadedTable
            }
        }

        let result = loadedTable[key]
        if result == nil {
            LingohubLogger.shared.log("Cache Manager: Key '\(key)' not found in table '\(effectiveTableName)' lang '\(effectiveLanguage)'.")
        }
        return result
    }

    /// Loads a `.strings` table from the update bundle. Returns an empty table when the
    /// file is missing or unreadable, so failed lookups are cached and not retried.
    private func loadStringsTable(tableName: String, language: String) -> [String: String] {
        guard let updateBundle = self.updateBundle else {
            LingohubLogger.shared.log("Cache Manager: Update bundle not found, cannot load strings.")
            return [:]
        }

        guard let lprojPath = updateBundle.path(forResource: language, ofType: "lproj"),
              let lprojBundle = Bundle(path: lprojPath) else {
            LingohubLogger.shared.log("Cache Manager: Could not find '\(language).lproj' in update bundle.")
            return [:]
        }

        guard let stringsFilePath = lprojBundle.path(forResource: tableName, ofType: "strings") else {
            LingohubLogger.shared.log("Cache Manager: Could not find '\(tableName).strings' in '\(language).lproj'.")
            return [:]
        }

        LingohubLogger.shared.log("Cache Manager: Loading strings from: \(stringsFilePath)")
        guard let stringsDict = NSDictionary(contentsOfFile: stringsFilePath) as? [String: String] else {
            LingohubLogger.shared.log("Cache Manager: Failed to load or parse '\(tableName).strings'")
            return [:]
        }

        LingohubLogger.shared.log("Cache Manager: Loaded \(stringsDict.count) strings for table '\(tableName)' lang '\(language)'.")
        return stringsDict
    }

    /// Clears the internal localization cache.
    func clearCache() {
        lock.lh_withLock {
            localizationCache.removeAll()
            cacheGeneration &+= 1
        }
        LingohubLogger.shared.log("Cache Manager: Internal localization cache cleared.")
    }

    // MARK: - Update Bundle Access

    private static let updateBundleName = "update.bundle"

    /// Checks if the update bundle file exists on disk.
    var updateBundleExists: Bool {
        guard let url = self.updateBundleUrl else {
            return false
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// The full URL to the Lingohub folder in Application Support, or nil if it can't be determined.
    var updateBundleFolderUrl: URL? {
        guard let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return applicationSupport.appendingPathComponent(LingohubConstants.folderName)
    }

    /// The full URL to the `update.bundle` directory within the Lingohub folder.
    var updateBundleUrl: URL? {
        return updateBundleFolderUrl?.appendingPathComponent(LocalizationCacheManager.updateBundleName)
    }

    /// The `Bundle` object representing the downloaded update bundle, or nil if it doesn't exist.
    var updateBundle: Bundle? {
        guard let bundleUrl = updateBundleUrl, updateBundleExists else {
            return nil
        }
        return Bundle(url: bundleUrl)
    }

    // MARK: - Storage housekeeping

    /// Moves the update bundle folder from its legacy location (`Documents/Lingohub`,
    /// used by SDK 1.0.x) to Application Support and excludes it from backups.
    func migrateLegacyStorageIfNeeded() {
        let fileManager = FileManager.default
        guard let legacyUrl = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent(LingohubConstants.folderName),
              let currentUrl = updateBundleFolderUrl,
              legacyUrl != currentUrl,
              fileManager.fileExists(atPath: legacyUrl.path) else {
            return
        }

        do {
            if fileManager.fileExists(atPath: currentUrl.path) {
                // Both exist: keep the current one, drop the legacy leftover.
                try fileManager.removeItem(at: legacyUrl)
            } else {
                try fileManager.createDirectory(at: currentUrl.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.moveItem(at: legacyUrl, to: currentUrl)
            }
            excludeFromBackup(currentUrl)
            LingohubLogger.shared.log("Cache Manager: Migrated update bundle storage to Application Support.")
        } catch {
            LingohubLogger.shared.log("Cache Manager: Storage migration failed: \(error)")
        }
    }

    /// Marks the given URL as excluded from backups. Downloaded translations are
    /// re-downloadable data and don't belong in device backups.
    func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do {
            try url.setResourceValues(values)
        } catch {
            LingohubLogger.shared.log("Cache Manager: Could not exclude \(url.lastPathComponent) from backup: \(error)")
        }
    }
}

extension NSLock {
    func lh_withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

//
//  LocalizationCacheManager.swift
//
//  Created by Manfred Baldauf on 31.03.25.
//

import Foundation

/// The complete, immutable description of an active downloaded release.
///
/// All state that decides how a localization lookup behaves lives in one value that
/// is swapped atomically: readers either see the previous release or the new one,
/// never a mix of filesystem, UserDefaults, and cache state.
struct LocalizationSnapshot {
    let bundle: Bundle
    let bundleURL: URL
    let distributionVersion: String
    let appVersion: String
}

/// Thread-safe store for the localization state the SDK shares with the swizzled
/// `Bundle.localizedString(forKey:value:table:)` implementation.
///
/// `NSLocalizedString` can be called from any thread, so everything in here must be
/// safe to access without main-actor isolation: all mutable state is protected by a
/// lock. The hot path (`getString`, `languageBundle(for:)`, `isUpdateActive`) never
/// touches the filesystem or UserDefaults — it only reads the in-memory snapshot.
final class LocalizationCacheManager: @unchecked Sendable {

    static let shared = LocalizationCacheManager()

    private let lock = NSLock()

    /// The active downloaded release, or nil when lookups should use the app bundle only.
    private var _snapshot: LocalizationSnapshot?
    // Internal cache for loaded strings [Language: [TableName: [Key: Value]]]
    private var localizationCache: [String: [String: [String: String]]] = [:]
    // Resolved per-language bundles inside the active release (`<lang>.lproj`, or the
    // release root when the language folder is missing).
    private var languageBundleCache: [String: Bundle] = [:]
    // Bumped on every cache clear so in-flight table loads from a previous
    // bundle can't be written back into the freshly cleared cache.
    private var cacheGeneration: UInt64 = 0
    private var _language: String?
    private var _swizzledBundlePaths: [String] = []
    // Storage roots can be overridden (by tests) so nothing ever touches the real
    // user directories; nil means the standard user-domain locations are used.
    private var _storageRootOverride: URL?
    private var _legacyStorageRootOverride: URL?

    init() {}

    /// Replaces Application Support as the parent of the LingoHub folder. Test hook.
    var storageRootOverride: URL? {
        get { lock.lh_withLock { _storageRootOverride } }
        set { lock.lh_withLock { _storageRootOverride = newValue } }
    }

    /// Replaces Documents as the parent of the legacy LingoHub folder. Test hook.
    var legacyStorageRootOverride: URL? {
        get { lock.lh_withLock { _legacyStorageRootOverride } }
        set { lock.lh_withLock { _legacyStorageRootOverride = newValue } }
    }

    // MARK: - Shared state

    /// The language override (or nil to follow the system language).
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

    // MARK: - Active release snapshot

    var currentSnapshot: LocalizationSnapshot? {
        return lock.lh_withLock { _snapshot }
    }

    /// Whether a downloaded update bundle is active and should be used for lookups.
    var isUpdateActive: Bool {
        return currentSnapshot != nil
    }

    var distributionVersion: String? {
        return currentSnapshot?.distributionVersion
    }

    var updateAppVersion: String? {
        return currentSnapshot?.appVersion
    }

    var updateBundle: Bundle? {
        return currentSnapshot?.bundle
    }

    /// Publishes a freshly installed release as the active snapshot and clears all
    /// caches, as one transaction: a reader either sees the old release with the old
    /// cache or the new release with an empty cache.
    ///
    /// - Returns: false when no `Bundle` can be created at `bundleURL`.
    @discardableResult
    func activate(bundleURL: URL, distributionVersion: String, appVersion: String) -> Bool {
        guard let bundle = Bundle(url: bundleURL) else {
            LingoHubLogger.shared.log("Cache Manager: could not create Bundle at \(bundleURL.path)")
            return false
        }
        let snapshot = LocalizationSnapshot(
            bundle: bundle,
            bundleURL: bundleURL,
            distributionVersion: distributionVersion,
            appVersion: appVersion
        )
        lock.lh_withLock {
            _snapshot = snapshot
            localizationCache.removeAll()
            languageBundleCache.removeAll()
            cacheGeneration &+= 1
        }
        LingoHubLogger.shared.log("Cache Manager: activated release \(distributionVersion)")
        return true
    }

    /// Removes the active snapshot and clears all caches. Lookups fall back to the
    /// original app bundle afterwards.
    func deactivate() {
        lock.lh_withLock {
            _snapshot = nil
            localizationCache.removeAll()
            languageBundleCache.removeAll()
            cacheGeneration &+= 1
        }
    }

    /// Rebuilds the snapshot from persisted metadata and the bundle on disk, healing
    /// any partial state a crash may have left behind:
    /// - metadata without a usable bundle → metadata is cleared, no update active
    /// - a bundle without metadata → the unreferenced bundle is deleted
    func restoreFromDisk() {
        let defaults = UserDefaults.standard
        let distributionVersion = defaults.string(forKey: LingoHubConstants.distributionVersion)
        let appVersion = defaults.string(forKey: LingoHubConstants.appVersion)

        guard let distributionVersion, let appVersion else {
            if let bundleURL = updateBundleUrl, FileManager.default.fileExists(atPath: bundleURL.path) {
                LingoHubLogger.shared.log("Cache Manager: removing unreferenced update bundle")
                try? FileManager.default.removeItem(at: bundleURL)
            }
            deactivate()
            return
        }

        guard let bundleURL = updateBundleUrl,
              bundleLooksUsable(at: bundleURL),
              activate(bundleURL: bundleURL, distributionVersion: distributionVersion, appVersion: appVersion) else {
            LingoHubLogger.shared.log("Cache Manager: persisted release \(distributionVersion) is missing or unusable, clearing state")
            defaults.removeObject(forKey: LingoHubConstants.distributionVersion)
            defaults.removeObject(forKey: LingoHubConstants.appVersion)
            deactivate()
            return
        }
    }

    /// A cheap structural check for a restored bundle: the directory exists and holds
    /// at least one `.lproj`. Freshly installed releases are fully validated by the
    /// installer before activation; this only guards against partial pre-2.0 leftovers.
    private func bundleLooksUsable(at url: URL) -> Bool {
        let contents = try? FileManager.default.contentsOfDirectory(atPath: url.path)
        return contents?.contains { $0.hasSuffix(".lproj") } ?? false
    }

    // MARK: - Cache Management

    /// Retrieves a string from the custom cache, loading the necessary .strings file if needed.
    /// - Parameters:
    ///   - key: The localization key.
    ///   - tableName: The name of the .strings file (without extension, defaults to "Localizable").
    ///   - language: The ISO language code (e.g., "en", "de").
    /// - Returns: The localized string, or nil if not found.
    func getString(forKey key: String, tableName: String?, language inputLanguage: String?) -> String? {
        guard let snapshot = currentSnapshot else {
            // No update bundle in use, skip the custom cache.
            return nil
        }

        // Determine the language and table name to use
        let effectiveLanguage = inputLanguage ?? language ?? Locale.lingohubLanguageCode ?? "en"
        let effectiveTableName = tableName ?? "Localizable" // Default table name

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
            return cachedString
        }
        if tableWasLoaded {
            return nil
        }

        // 2. Load the .strings file for the language and table from the update bundle.
        //    Loading happens outside the lock; concurrent loads are idempotent.
        LingoHubLogger.shared.log("Cache Manager: Miss for table '\(effectiveTableName)' lang '\(effectiveLanguage)'. Attempting to load.")
        let loadedTable = loadStringsTable(tableName: effectiveTableName, language: effectiveLanguage, from: snapshot.bundle)

        lock.lh_withLock {
            // Only store the table if the cache wasn't cleared while we were loading,
            // otherwise a table read from the previous bundle would survive the clear.
            if generation == cacheGeneration {
                localizationCache[effectiveLanguage, default: [:]][effectiveTableName] = loadedTable
            }
        }

        return loadedTable[key]
    }

    /// Loads a `.strings` table from the given release bundle. Returns an empty table
    /// when the file is missing or unreadable, so failed lookups are cached and not retried.
    private func loadStringsTable(tableName: String, language: String, from updateBundle: Bundle) -> [String: String] {
        guard let lprojPath = updateBundle.path(forResource: language, ofType: "lproj"),
              let lprojBundle = Bundle(path: lprojPath) else {
            LingoHubLogger.shared.log("Cache Manager: Could not find '\(language).lproj' in update bundle.")
            return [:]
        }

        guard let stringsFilePath = lprojBundle.path(forResource: tableName, ofType: "strings") else {
            LingoHubLogger.shared.log("Cache Manager: Could not find '\(tableName).strings' in '\(language).lproj'.")
            return [:]
        }

        guard let stringsDict = NSDictionary(contentsOfFile: stringsFilePath) as? [String: String] else {
            LingoHubLogger.shared.log("Cache Manager: Failed to load or parse '\(tableName).strings'")
            return [:]
        }

        LingoHubLogger.shared.log("Cache Manager: Loaded \(stringsDict.count) strings for table '\(tableName)' lang '\(language)'.")
        return stringsDict
    }

    /// The language-specific bundle (`<language>.lproj`) inside the active release,
    /// the release root when that language folder is missing, or nil when no release
    /// is active. Resolutions are cached; the cache is dropped on activate/deactivate.
    func languageBundle(for language: String?) -> Bundle? {
        guard let snapshot = currentSnapshot else { return nil }
        guard let language else { return snapshot.bundle }

        let capturedGeneration: UInt64 = lock.lh_withLock { cacheGeneration }
        if let cached = lock.lh_withLock({ languageBundleCache[language] }) {
            return cached
        }

        let resolved: Bundle
        if let lprojPath = snapshot.bundle.path(forResource: language, ofType: "lproj"),
           let lprojBundle = Bundle(path: lprojPath) {
            resolved = lprojBundle
        } else {
            resolved = snapshot.bundle
        }

        lock.lh_withLock {
            if capturedGeneration == cacheGeneration {
                languageBundleCache[language] = resolved
            }
        }
        return resolved
    }

    /// Clears the internal localization cache.
    func clearCache() {
        lock.lh_withLock {
            localizationCache.removeAll()
            languageBundleCache.removeAll()
            cacheGeneration &+= 1
        }
        LingoHubLogger.shared.log("Cache Manager: Internal localization cache cleared.")
    }

    // MARK: - Update Bundle Access

    private static let updateBundleName = "update.bundle"

    /// Checks if the update bundle directory exists on disk.
    var updateBundleExists: Bool {
        guard let url = self.updateBundleUrl else {
            return false
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// The full URL to the LingoHub folder in Application Support, or nil if it can't be determined.
    var updateBundleFolderUrl: URL? {
        let root = storageRootOverride ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return root?.appendingPathComponent(LingoHubConstants.folderName)
    }

    /// The LingoHub folder location used by SDK 1.0.x (in Documents).
    var legacyUpdateBundleFolderUrl: URL? {
        let root = legacyStorageRootOverride ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        return root?.appendingPathComponent(LingoHubConstants.folderName)
    }

    /// The full URL to the `update.bundle` directory within the LingoHub folder.
    var updateBundleUrl: URL? {
        return updateBundleFolderUrl?.appendingPathComponent(LocalizationCacheManager.updateBundleName)
    }

    // MARK: - Storage housekeeping

    /// Removes staging directories a crashed install may have left behind.
    func removeStagingLeftovers() {
        let fileManager = FileManager.default
        guard let folderUrl = updateBundleFolderUrl,
              let entries = try? fileManager.contentsOfDirectory(at: folderUrl, includingPropertiesForKeys: nil) else {
            return
        }
        for entry in entries where entry.lastPathComponent.hasPrefix(LingoHubConstants.stagingDirectoryPrefix) {
            LingoHubLogger.shared.log("Cache Manager: removing staging leftover \(entry.lastPathComponent)")
            try? fileManager.removeItem(at: entry)
        }
    }

    /// Moves the update bundle folder from its legacy location (`Documents/LingoHub`,
    /// used by SDK 1.0.x) to Application Support and excludes it from backups.
    func migrateLegacyStorageIfNeeded() {
        let fileManager = FileManager.default
        guard let legacyUrl = legacyUpdateBundleFolderUrl,
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
            LingoHubLogger.shared.log("Cache Manager: Migrated update bundle storage to Application Support.")
        } catch {
            LingoHubLogger.shared.log("Cache Manager: Storage migration failed: \(error)")
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
            LingoHubLogger.shared.log("Cache Manager: Could not exclude \(url.lastPathComponent) from backup: \(error)")
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

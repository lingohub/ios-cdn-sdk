//
//  LocalizationCacheManager.swift
//
//  Created by Manfred Baldauf on 31.03.25.
//

import Foundation

/// Manages the caching of localized strings fetched from the Lingohub update bundle
/// and provides access methods for the update bundle itself.
@MainActor internal final class LocalizationCacheManager {

    // Weak reference to the SDK to access shared state like language and logging
    private weak var sdk: LingohubSDK?

    // Internal cache for loaded strings [Language: [TableName: [Key: Value]]]
    private var localizationCache: [String: [String: [String: String]]] = [:]

    // MARK: - Initialization

    init(sdk: LingohubSDK) {
        self.sdk = sdk
    }

    // MARK: - Cache Management

    /// Retrieves a string from the custom cache, loading the necessary .strings file if needed.
    /// - Parameters:
    ///   - key: The localization key.
    ///   - tableName: The name of the .strings file (without extension, defaults to "Localizable").
    ///   - language: The ISO language code (e.g., "en", "de").
    /// - Returns: The localized string, or nil if not found.
    func getString(forKey key: String, tableName: String?, language inputLanguage: String?) -> String? {
        // Ensure we should be using the update bundle via the SDK's state
        guard let sdk = sdk, sdk.isUpdatedBundleUsed else {
            // sdk is nil or updated bundle shouldn't be used, skip custom cache.
            // Logging this might be noisy if called frequently before SDK is ready.
            return nil
        }

        // Determine the language and table name to use
        let effectiveLanguage = inputLanguage ?? sdk.language ?? Locale.current.languageCode ?? "en"
        let effectiveTableName = tableName ?? "Localizable" // Default table name

         LingohubLogger.shared.log("Cache Manager: Attempting get string '\(key)' table '\(effectiveTableName)' lang '\(effectiveLanguage)'")


        // 1. Check if the language and table are already cached
        if let tableCache = localizationCache[effectiveLanguage], let cachedString = tableCache[effectiveTableName]?[key] {
            LingohubLogger.shared.log("Cache Manager: Hit for key '\(key)'")
            return cachedString
        }

        // 2. Check if the table for this language was loaded previously (and the key was just missing)
        if localizationCache[effectiveLanguage]?[effectiveTableName] != nil {
            LingohubLogger.shared.log("Cache Manager: Table '\(effectiveTableName)' lang '\(effectiveLanguage)' loaded previously, but key '\(key)' missing.")
            return nil // Table was loaded, key doesn't exist
        }

        // 3. Load the .strings file for the language and table from the update bundle
        LingohubLogger.shared.log("Cache Manager: Miss for table '\(effectiveTableName)' lang '\(effectiveLanguage)'. Attempting to load.")

        // Get the update bundle using the moved logic
        guard let updateBundle = self.updateBundle else {
            LingohubLogger.shared.log("Cache Manager: Update bundle not found, cannot load strings.")
            // Initialize cache for this language/table as empty to prevent repeated load attempts
            localizationCache[effectiveLanguage, default: [:]][effectiveTableName] = [:]
            return nil
        }

        guard let lprojPath = updateBundle.path(forResource: effectiveLanguage, ofType: "lproj"),
              let lprojBundle = Bundle(path: lprojPath) else {
            LingohubLogger.shared.log("Cache Manager: Could not find '\(effectiveLanguage).lproj' in update bundle.")
            localizationCache[effectiveLanguage, default: [:]][effectiveTableName] = [:]
            return nil
        }

        let stringsFileName = "\(effectiveTableName).strings"
        guard let stringsFilePath = lprojBundle.path(forResource: effectiveTableName, ofType: "strings") else {
            LingohubLogger.shared.log("Cache Manager: Could not find '\(stringsFileName)' in '\(effectiveLanguage).lproj'.")
            localizationCache[effectiveLanguage, default: [:]][effectiveTableName] = [:]
            return nil
        }

            LingohubLogger.shared.log("Cache Manager: Loading strings from: \(stringsFilePath)")
        guard let stringsDict = NSDictionary(contentsOfFile: stringsFilePath) as? [String: String] else {
            LingohubLogger.shared.log("Cache Manager: Failed to load or parse '\(stringsFileName)'")
            localizationCache[effectiveLanguage, default: [:]][effectiveTableName] = [:]
            return nil
        }

        LingohubLogger.shared.log("Cache Manager: Loaded \(stringsDict.count) strings for table '\(effectiveTableName)' lang '\(effectiveLanguage)'.")
        // Store the loaded strings in the cache
        localizationCache[effectiveLanguage, default: [:]][effectiveTableName] = stringsDict

        // Return the requested key from the newly loaded cache
        let result = stringsDict[key]
        if result == nil {
            LingohubLogger.shared.log("Cache Manager: Key '\(key)' not found in newly loaded table '\(effectiveTableName)' lang '\(effectiveLanguage)'.")
        }
        return result
    }

    /// Clears the internal localization cache.
    func clearCache() {
        localizationCache.removeAll()
        LingohubLogger.shared.log("Cache Manager: Internal localization cache cleared.")
    }

    // MARK: - Update Bundle Access

    private static let updateBundleName = "update.bundle"

    /// Checks if the update bundle file exists on disk.
    var updateBundleExists: Bool {
        guard let url = self.updateBundleUrl else {
            return false
        }
        let exists = FileManager.default.fileExists(atPath: url.path)
        return exists
    }

    /// The full URL to the update bundle directory, or nil if the documents directory can't be determined.
    var updateBundleFolderUrl: URL? {
        guard let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        return documentsDirectory.appendingPathComponent(LingohubConstants.folderName)
    }


    /// The full URL to the `update.bundle` file within the Lingohub documents folder.
    var updateBundleUrl: URL? {
        return updateBundleFolderUrl?.appendingPathComponent(LocalizationCacheManager.updateBundleName)
    }

    /// The `Bundle` object representing the downloaded update bundle, or nil if it doesn't exist.
    var updateBundle: Bundle? {
        guard let bundleUrl = updateBundleUrl, updateBundleExists else {
            LingohubLogger.shared.log("Cache Manager: Update bundle requested but URL is nil or file doesn't exist.")
            return nil
        }
        LingohubLogger.shared.log("Cache Manager: Returning update bundle instance for URL: \(bundleUrl)")
        return Bundle(url: bundleUrl)
    }
}

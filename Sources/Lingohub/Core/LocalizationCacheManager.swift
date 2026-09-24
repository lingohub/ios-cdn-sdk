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
    /// Distinguishes activations, so work started for one snapshot (a merged-bundle
    /// build) can never attach to a later one.
    let id: UInt64
    let bundle: Bundle
    let bundleURL: URL
    let distributionVersion: String
    let appVersion: String
    /// Serves this release to Swift-native lookups via `Bundle.lingohub`; nil until it
    /// has been built, or when it could not be.
    var mergedBundle: MergedBundle?
}

/// Thread-safe store for the localization state the SDK shares with the swizzled
/// `Bundle.localizedString(forKey:value:table:)` implementation and `Bundle.lingohub`.
///
/// `NSLocalizedString` can be called from any thread, so everything in here must be
/// safe to access without main-actor isolation: all mutable state is protected by a
/// lock. The hot path (`getString`, `languageBundle(for:)`, `isUpdateActive`,
/// `lingohubBundle`) never touches the filesystem or UserDefaults — it only reads the
/// in-memory snapshot.
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
    // Paths of every release activated in this process. A lookup that resolved a
    // release's bundle before the next release was activated still reads from it
    // (Foundation loads tables lazily), so none of these is deleted while the process
    // runs; the next launch removes those no metadata refers to.
    private var releasesInUse: Set<String> = []
    private var lastSnapshotID: UInt64 = 0
    // Every merged bundle activated in this process. Views and resources may still
    // resolve against any of them, and Foundation reads their tables lazily, so none is
    // deleted while the process runs; the next launch removes the unused ones.
    private var _mergedBundlesInUse: Set<URL> = []
    private var _language: String?
    private var _swizzledBundlePaths: [String] = []
    // Storage roots can be overridden (by tests) so nothing ever touches the real
    // user directories; nil means the standard user-domain locations are used.
    private var _storageRootOverride: URL?
    private var _legacyStorageRootOverride: URL?
    private var _baseBundleOverride: Bundle?

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

    /// Replaces `Bundle.main` as the app bundle merged bundles are built from. Test hook.
    var baseBundleOverride: Bundle? {
        get { lock.lh_withLock { _baseBundleOverride } }
        set { lock.lh_withLock { _baseBundleOverride = newValue } }
    }

    /// The app bundle whose string tables merged bundles are built from.
    var baseBundle: Bundle {
        return baseBundleOverride ?? .main
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
    /// cache (and old merged bundle) or the new release with an empty cache (and its
    /// merged bundle).
    ///
    /// - Returns: false when no `Bundle` can be created at `bundleURL`.
    @discardableResult
    func activate(bundleURL: URL, distributionVersion: String, appVersion: String, mergedBundle: MergedBundle? = nil) -> Bool {
        guard let bundle = Bundle(url: bundleURL) else {
            LingoHubLogger.shared.log("Cache Manager: could not create Bundle at \(bundleURL.path)")
            return false
        }
        lock.lh_withLock {
            lastSnapshotID &+= 1
            _snapshot = LocalizationSnapshot(
                id: lastSnapshotID,
                bundle: bundle,
                bundleURL: bundleURL,
                distributionVersion: distributionVersion,
                appVersion: appVersion,
                mergedBundle: mergedBundle
            )
            localizationCache.removeAll()
            languageBundleCache.removeAll()
            cacheGeneration &+= 1
            releasesInUse.insert(bundleURL.path)
            if let mergedBundle {
                _mergedBundlesInUse.insert(mergedBundle.url)
            }
        }
        LingoHubLogger.shared.log("Cache Manager: activated release \(distributionVersion)")
        return true
    }

    /// Attaches a merged bundle built after its release was activated (at launch).
    ///
    /// - Returns: false, attaching nothing, when the snapshot the bundle was built for
    ///   is no longer active (a newer release was installed, or it was discarded).
    @discardableResult
    func attachMergedBundle(_ mergedBundle: MergedBundle, toSnapshot snapshotID: UInt64) -> Bool {
        return lock.lh_withLock {
            guard _snapshot?.id == snapshotID else { return false }
            _snapshot?.mergedBundle = mergedBundle
            _mergedBundlesInUse.insert(mergedBundle.url)
            return true
        }
    }

    /// The merged bundles activated in this process (see `_mergedBundlesInUse`).
    var mergedBundlesInUse: [URL] {
        return lock.lh_withLock { Array(_mergedBundlesInUse) }
    }

    /// Forgets which merged bundles this process activated, as a new process would. Test hook.
    func forgetMergedBundlesInUse() {
        lock.lh_withLock { _mergedBundlesInUse.removeAll() }
    }

    /// The bundle Swift-native lookups use (`Bundle.lingohub`), or nil when no merged
    /// bundle is active. Honors the language override. Memory only, like the other
    /// lookup paths: safe and cheap to call from any thread, as often as views render.
    var lingohubBundle: Bundle? {
        return lock.lh_withLock {
            _snapshot?.mergedBundle?.bundle(forLanguage: _language)
        }
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

    /// Rebuilds the snapshot from persisted metadata and the release on disk, healing
    /// any partial state a crash may have left behind:
    /// - metadata without a usable release → metadata is cleared, no update active
    /// - releases the metadata does not refer to (installed, but the app terminated
    ///   before the metadata was persisted) and install leftovers → deleted
    func restoreFromDisk() {
        let defaults = UserDefaults.standard
        let distributionVersion = defaults.string(forKey: LingoHubConstants.distributionVersion)
        let appVersion = defaults.string(forKey: LingoHubConstants.appVersion)

        guard let distributionVersion, let appVersion else {
            removeReleases(keeping: nil)
            deactivate()
            return
        }

        guard let releaseURL = persistedReleaseUrl,
              bundleLooksUsable(at: releaseURL),
              activate(bundleURL: releaseURL, distributionVersion: distributionVersion, appVersion: appVersion) else {
            LingoHubLogger.shared.log("Cache Manager: persisted release \(distributionVersion) is missing or unusable, clearing state")
            clearPersistedRelease()
            removeReleases(keeping: nil)
            deactivate()
            return
        }
        removeReleases(keeping: releaseURL)
    }

    /// Records `releaseURL` as the active release. The folder is written before the
    /// release metadata: a termination in between pairs the new release with the
    /// previous release ID, which the next update check corrects by downloading the
    /// release again. The reverse order would leave the previous content under the new
    /// ID, which no update check corrects.
    func persistRelease(at releaseURL: URL, distributionVersion: String, appVersion: String) {
        let defaults = UserDefaults.standard
        defaults.set(releaseURL.lastPathComponent, forKey: LingoHubConstants.releaseDirectory)
        defaults.set(distributionVersion, forKey: LingoHubConstants.distributionVersion)
        defaults.set(appVersion, forKey: LingoHubConstants.appVersion)
    }

    /// Forgets which releases this process activated, as a new process would. Test hook.
    func forgetReleasesInUse() {
        lock.lh_withLock { releasesInUse.removeAll() }
    }

    /// Removes the persisted release metadata.
    func clearPersistedRelease() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: LingoHubConstants.distributionVersion)
        defaults.removeObject(forKey: LingoHubConstants.appVersion)
        defaults.removeObject(forKey: LingoHubConstants.releaseDirectory)
    }

    /// The release folder the persisted metadata refers to: the folder named by
    /// `persistRelease`, or `fixedUpdateBundleUrl` for a release installed by an earlier
    /// SDK version (no folder name persisted). nil when the persisted name is not a plain
    /// folder name, which the SDK never writes.
    var persistedReleaseUrl: URL? {
        guard let name = UserDefaults.standard.string(forKey: LingoHubConstants.releaseDirectory) else {
            return fixedUpdateBundleUrl
        }
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            return nil
        }
        return releasesFolderUrl?.appendingPathComponent(name, isDirectory: true)
    }

    /// Deletes installed releases other than `kept` and those this process activated
    /// (see `releasesInUse`), plus leftovers of interrupted installs, from both the
    /// release folder and the fixed location earlier SDK versions used.
    private func removeReleases(keeping kept: URL?) {
        let fileManager = FileManager.default
        var installed: [URL] = []
        if let fixedURL = fixedUpdateBundleUrl, fileManager.fileExists(atPath: fixedURL.path) {
            installed.append(fixedURL)
        }
        if let folderURL = releasesFolderUrl, let names = try? fileManager.contentsOfDirectory(atPath: folderURL.path) {
            installed += names.map { folderURL.appendingPathComponent($0, isDirectory: true) }
        }
        var retained = lock.lh_withLock { releasesInUse }
        if let kept {
            retained.insert(kept.path)
        }
        for url in installed where !retained.contains(url.path) {
            do {
                try fileManager.removeItem(at: url)
                LingoHubLogger.shared.log("Cache Manager: removed unreferenced release \(url.lastPathComponent)")
            } catch {
                LingoHubLogger.shared.log("Cache Manager: could not remove unreferenced release \(url.lastPathComponent): \(error)")
            }
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
        let effectiveTableName = tableName ?? "Localizable" // Default table name

        // 1. Capture the snapshot, its generation, and the cache read under ONE lock
        //    acquisition. Reading them separately would let an activate() slip in
        //    between, after which a table loaded from the old release could pass the
        //    generation guard and be cached for the new release indefinitely.
        var snapshot: LocalizationSnapshot?
        var generation: UInt64 = 0
        var tableWasLoaded = false
        var effectiveLanguage = ""
        let cachedString: String? = lock.lh_withLock {
            guard let current = _snapshot else { return nil }
            snapshot = current
            generation = cacheGeneration
            // `_language` directly: the `language` accessor takes this (non-recursive) lock.
            effectiveLanguage = inputLanguage ?? _language ?? Locale.lingohubLanguageCode ?? "en"
            if let table = localizationCache[effectiveLanguage]?[effectiveTableName] {
                tableWasLoaded = true
                return table[key]
            }
            return nil
        }

        guard let snapshot else {
            // No update bundle in use, skip the custom cache.
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
        guard let language else { return currentSnapshot?.bundle }

        // Snapshot, generation, and the cache read are captured under one lock
        // acquisition, for the same reason as in getString: a bundle resolved from
        // the old release must never be cached for the new one.
        var snapshot: LocalizationSnapshot?
        var generation: UInt64 = 0
        let cached: Bundle? = lock.lh_withLock {
            guard let current = _snapshot else { return nil }
            snapshot = current
            generation = cacheGeneration
            return languageBundleCache[language]
        }

        guard let snapshot else { return nil }
        if let cached { return cached }

        let resolved: Bundle
        if let lprojPath = snapshot.bundle.path(forResource: language, ofType: "lproj"),
           let lprojBundle = Bundle(path: lprojPath) {
            resolved = lprojBundle
        } else {
            resolved = snapshot.bundle
        }

        lock.lh_withLock {
            if generation == cacheGeneration {
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

    private static let fixedUpdateBundleName = "update.bundle"

    /// Whether an installed release exists on disk.
    var updateBundleExists: Bool {
        let fileManager = FileManager.default
        if let fixedURL = fixedUpdateBundleUrl, fileManager.fileExists(atPath: fixedURL.path) {
            return true
        }
        guard let folderURL = releasesFolderUrl,
              let names = try? fileManager.contentsOfDirectory(atPath: folderURL.path) else {
            return false
        }
        return names.contains { $0.hasSuffix(".bundle") }
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

    /// The folder releases are installed into, each under a name of its own.
    var releasesFolderUrl: URL? {
        return updateBundleFolderUrl?.appendingPathComponent(LingoHubConstants.releasesFolderName, isDirectory: true)
    }

    /// A fresh location to install a release to. Foundation caches bundles, and the
    /// string tables it loaded from them, by path: a release installed over the previous
    /// one's path would keep being read through the previous release's cache (stale
    /// `.stringsdict` plurals, missing new tables) until the next launch.
    func makeReleaseUrl() -> URL? {
        return releasesFolderUrl?.appendingPathComponent(UUID().uuidString + ".bundle", isDirectory: true)
    }

    /// Where earlier SDK versions installed every release, reusing the path
    /// (`Lingohub/update.bundle`). Still read while no release folder is persisted, so
    /// those installs survive the upgrade; the next install supersedes it.
    var fixedUpdateBundleUrl: URL? {
        return updateBundleFolderUrl?.appendingPathComponent(LocalizationCacheManager.fixedUpdateBundleName, isDirectory: true)
    }

    /// The folder merged bundles (`<id>.bundle`) are built in, next to `update.bundle`,
    /// so they share its backup exclusion and are discarded along with it.
    var mergedBundlesFolderUrl: URL? {
        return updateBundleFolderUrl?.appendingPathComponent(LingoHubConstants.mergedBundlesFolderName)
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

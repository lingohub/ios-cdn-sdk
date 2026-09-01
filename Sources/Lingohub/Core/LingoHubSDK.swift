//
//  LingoHubSDK.swift
//
//
//  Created by Manfred Baldauf on 12.03.25.
//

import Foundation

/**
 LingoHub iOS SDK
 Use this SDK to update your localizable strings without the need of an app update.
 */
@MainActor public final class LingoHubSDK {
    /**
     The shared instance of the LingoHub SDK
     */
    public static let shared = LingoHubSDK()

    public var environment: Environment = .production

    @objc var apiKey: String?
    @objc var appVersion: String?
    @objc var sdkVersion: String?

    /**
     The language override, or `nil` when the SDK follows the system language.

     Setting this property behaves exactly like calling ``setLanguage(_:)`` (a non-nil
     value is persisted and restored on the next launch) or ``setSystemLanguage()``
     (`nil` removes the persisted override). For the language actually being served,
     use ``currentLanguageCode``.
     */
    @objc public var language: String? {
        get { cacheManager.language }
        set {
            if let newValue {
                setLanguage(newValue)
            } else {
                setSystemLanguage()
            }
        }
    }

    /**
     The ISO 639-1 code of the language the SDK is currently serving: the override set
     via `setLanguage(_:)`, or the system language when no override is active.
     */
    @objc public var currentLanguageCode: String? {
        return effectiveLanguageCode
    }

    var apiClient: any APIClientProtocol = APIClient(basePath: LingoHubConstants.basePath)
    var installer = UpdateInstaller()
    let cacheManager = LocalizationCacheManager.shared

    /// The running update cycle, if any. Concurrent `update`/`updateAsync` calls
    /// join it instead of starting a second network round-trip and install.
    private var inFlightUpdate: Task<Bool, Error>?

    @objc var swizzledBundles: [String] {
        get { cacheManager.swizzledBundlePaths }
        set { cacheManager.swizzledBundlePaths = newValue }
    }

    private var deviceIdentifier: String?
    internal init() {}

}

// MARK: Public Interface

public extension LingoHubSDK {
    /**
     Configure the LingoHub SDK. Call this method before any others.

     - Parameter apiKey: Your LingoHub API Key.
     - Parameter appVersion: The version of your app. If nil, the *CFBundleShortVersionString* from the Info.plist File is used.
     - Parameter environment: The environment to use. Default is .production.
     - Parameter logLevel: The log level to use. Default is .none.
     */
    func configure(withApiKey apiKey: String, appVersion: String? = nil, environment: Environment = .production, logLevel: LogLevel = .none) {
        self.apiKey = apiKey
        self.sdkVersion = LingoHubConstants.version
        self.deviceIdentifier = Device.identifier
        self.environment = environment
        // Configure the logger's enabled state
        LingoHubLogger.shared.logLevel = logLevel

        guard let version = appVersion ?? Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else {
            assertionFailure("Please provide an AppVersion")
            return
        }

        LingoHubLogger.shared.log("App version: \(version), environment: \(environment.rawValue)")

        // Move translations downloaded by SDK 1.0.x from Documents to Application Support
        cacheManager.migrateLegacyStorageIfNeeded()

        // Remove staging directories a crashed install may have left behind
        cacheManager.removeStagingLeftovers()

        // Restore the downloaded release from disk, healing partial state from
        // crashed installs (missing bundle, missing metadata)
        cacheManager.restoreFromDisk()

        // if the app version has changed, remove all updated bundles
        if isUpdatedBundleUsed, let currentVersion = updateAppVersion, currentVersion != version {
            cleanUp()
        }

        // Restore only a persisted language override; nil means the SDK follows the
        // system language (see the `language` documentation).
        cacheManager.language = UserDefaults.standard.string(forKey: LingoHubConstants.languageOverride)

        self.appVersion = version
    }

    /**
     Override the system language. The override is persisted and restored on the next launch.

     - Parameter language: The ISO 639-1 two letter language code of the language, e.g. 'en' or 'de'
     */
    func setLanguage(_ language: String) {
        cacheManager.language = language
        UserDefaults.standard.set(language, forKey: LingoHubConstants.languageOverride)
    }

    /**
     Reset the language back to the system language and remove the persisted override.
     */
    func setSystemLanguage() {
        cacheManager.language = nil
        UserDefaults.standard.removeObject(forKey: LingoHubConstants.languageOverride)
    }

    /**
     Retrieve the updated string.

     - Parameter key: The key of your localization string
     - Parameter tableName: The file where your key is found (default is Localizable.strings)

     - Returns: The updated string or nil
     */
    func localizedString(forKey key: String, tableName: String? = nil) -> String? {
        return cacheManager.getString(forKey: key, tableName: tableName, language: language)
    }

    /**
     Swizzle the main Bundle of your Application.
     If swizzling is enabled just continue using *NSLocalizedString* methods as usual, LingoHub will do the rest.

     Swizzling stays active for the lifetime of the process; there is no API to
     disable it at runtime.
     */
    func swizzleMainBundle() {
        swizzleBundle(Bundle.main)
    }

    /**
     Swizzle the given bundle, in addition to any bundles that are already swizzled.
     If swizzling is enabled just continue using *NSLocalizedString* methods as usual, LingoHub will do the rest.

     - Parameter bundle: The bundle you want to enable swizzling for
     */
    func swizzleBundle(_ bundle: Bundle) {
        swizzleBundles([bundle])
    }

    /**
     Swizzle the given bundles, in addition to any bundles that are already swizzled.
     If swizzling is enabled just continue using *NSLocalizedString* methods as usual, LingoHub will do the rest.

     - Parameter bundles: The bundles you want to enable swizzling for
     */
    func swizzleBundles(_ bundles: [Bundle]) {
        let wasSwizzled = !swizzledBundles.isEmpty
        let newPaths = bundles.map({ $0.bundlePath }).filter { !swizzledBundles.contains($0) }
        swizzledBundles.append(contentsOf: newPaths)
        if !wasSwizzled && !swizzledBundles.isEmpty {
            Bundle.swizzle()
        }
    }

    /**
     Check if there are any localization updates available for your app on LingoHub
     Use the result-closure or the `LingoHubDidUpdateLocalization` notification as status callback

     The closure is always called on the main queue. Concurrent calls share one
     update cycle and receive the same result.

     - Parameter result: Closure to check for updated content. `True` means the content was updated, `False` that there was no new content.
     */
    func update(result: (@Sendable (Result<Bool, LingoHubSDKError>) -> Void)? = nil) {
        Task { @MainActor in
            do {
                let updated = try await updateAsync()
                result?(.success(updated))
            } catch let error as LingoHubSDKError {
                result?(.failure(error))
            } catch {
                result?(.failure(.unknown))
            }
        }
    }

    /**
     Check if there are any localization updates available for your app on LingoHub,
     using Swift concurrency.

     Named distinctly from `update(result:)` so that existing fire-and-forget
     `update()` calls in async contexts keep compiling unchanged.

     Concurrent calls join the running update cycle and receive its result instead
     of starting a second network round-trip.

     - Returns: `true` if new translations were downloaded and are active, `false` if there was nothing new.
     - Throws: `LingoHubSDKError` when the update check fails.
     */
    @discardableResult
    func updateAsync() async throws -> Bool {
        if let inFlightUpdate {
            return try await inFlightUpdate.value
        }
        let task = Task { try await self.performUpdate() }
        inFlightUpdate = task
        defer { inFlightUpdate = nil }
        return try await task.value
    }
}

// MARK: Public Swift Interface

public extension Notification.Name {
    /**
     Observe this notification to get notified when LingoHub has found updated localizations
     */
    static let LingoHubDidUpdateLocalization = Notification.Name(LingoHubConstants.updateNotification)
}


@available(swift, obsoleted: 1.0)
@objc public extension NSNotification {
    /**
     Observe this notification to get notified when LingoHub has found updated localizations
     */
    static var LingoHubDidUpdateLocalization: NSString {
        return NSString(string: LingoHubConstants.updateNotification)
    }
}

// MARK: Update Cycle

extension LingoHubSDK {
    /// Runs one complete update cycle: check → download → verify → install → publish.
    /// Throws `LingoHubSDKError` exclusively.
    private func performUpdate() async throws -> Bool {
        guard let sdkVersion = sdkVersion else {
            LingoHubLogger.shared.log("Error: Invalid SDK version")
            throw LingoHubSDKError.invalidSdkVersion
        }

        guard let appVersion = appVersion else {
            LingoHubLogger.shared.log("Error: Invalid app version")
            throw LingoHubSDKError.invalidAppVersion
        }

        guard let apiKey = apiKey else {
            LingoHubLogger.shared.log("Error: Invalid API key")
            throw LingoHubSDKError.invalidApiKey
        }

        // After a 429 (usage budget exhausted) the SDK pauses update checks for a while
        // instead of hammering the CDN.
        if let cooldownUntil = usageLimitCooldownUntil, cooldownUntil > Date() {
            LingoHubLogger.shared.log("Usage limit cooldown active until \(cooldownUntil), skipping update check")
            throw LingoHubSDKError.apiError(statusCode: 429, message: "Usage limit reached. Update checks are paused until \(cooldownUntil).", errorCodes: ["USAGE_LIMIT_EXCEEDED"])
        }

        LingoHubLogger.shared.log("Checking for updates (release: \(distributionVersion ?? "none"), environment: \(environment))")

        do {
            let bundleInfo = try await apiClient.checkForUpdates(
                apiKey: apiKey,
                appVersion: appVersion,
                sdkVersion: sdkVersion,
                distributionVersion: distributionVersion,
                environment: environment,
                deviceIdentifier: deviceIdentifier,
                languageCode: effectiveLanguageCode
            )

            // The CDN is HTTPS-only; a non-HTTPS download URL in the metadata means
            // something between the SDK and the CDN is broken or hostile.
            guard bundleInfo.filesUrl.scheme?.lowercased() == "https" else {
                LingoHubLogger.shared.log("Rejecting non-HTTPS download URL")
                throw LingoHubSDKError.apiError(statusCode: 0, message: "Insecure download URL rejected", errorCodes: [])
            }

            let archiveURL = try await apiClient.download(from: bundleInfo.filesUrl)
            defer { try? FileManager.default.removeItem(at: archiveURL) }

            try await installArchive(at: archiveURL, identifier: bundleInfo.id, appVersion: appVersion, expectedSha256: bundleInfo.filesSha256)
            return true
        } catch APIError.noContent {
            LingoHubLogger.shared.log("No content available for update")
            return false
        } catch APIError.apiError(404, _, let infos) where infos.contains("DISTRIBUTION_NOT_FOUND") {
            // The CDN's DISTRIBUTION_NOT_FOUND means no release matches this app version
            // and no fallback release exists (e.g. nothing has been published yet).
            // That is a normal state, not an error. Any other 404 stays a failure.
            LingoHubLogger.shared.log("No distribution release available for this app (404 DISTRIBUTION_NOT_FOUND)")
            return false
        } catch let error as LingoHubSDKError {
            throw error
        } catch APIError.apiError(let statusCode, let message, let infos) {
            LingoHubLogger.shared.log("API error: Status \(statusCode), Message: \(message ?? "No message")")
            if statusCode == 429 {
                // Usage budget exhausted; pause update checks client-side.
                UserDefaults.standard.set(Date().addingTimeInterval(LingoHubConstants.usageLimitCooldownInterval).timeIntervalSince1970, forKey: LingoHubConstants.usageCooldownUntil)
            }
            throw LingoHubSDKError.apiError(statusCode: statusCode, message: message, errorCodes: infos)
        } catch let error as DecodingError {
            let errorMessage = formatDecodingError(error)
            LingoHubLogger.shared.log("Decoding error: \(errorMessage)")
            throw LingoHubSDKError.apiError(statusCode: 0, message: errorMessage, errorCodes: [])
        } catch let error as URLError {
            // Transport failure before any response was received (offline, DNS, timeout):
            // statusCode 0 per the documented apiError contract.
            LingoHubLogger.shared.log("Network error: \(error.localizedDescription)")
            throw LingoHubSDKError.apiError(statusCode: 0, message: error.localizedDescription, errorCodes: [])
        } catch APIError.invalidURL {
            LingoHubLogger.shared.log("Invalid request URL")
            throw LingoHubSDKError.apiError(statusCode: 0, message: "Invalid request URL", errorCodes: [])
        } catch APIError.invalidResponse {
            LingoHubLogger.shared.log("Invalid response from the server")
            throw LingoHubSDKError.apiError(statusCode: 0, message: "Invalid response from the server", errorCodes: [])
        } catch {
            LingoHubLogger.shared.log("Unexpected error: \(error)")
            throw LingoHubSDKError.unknown
        }
    }

    /// Installs a downloaded release archive and publishes it:
    /// stage + validate + swap (off the main actor), then — back on the main actor —
    /// activate the new snapshot, persist the release metadata, and notify observers.
    /// Observers of `LingoHubDidUpdateLocalization` always see the new release.
    func installArchive(at archiveURL: URL, identifier: String, appVersion: String, expectedSha256: String? = nil) async throws {
        guard let liveBundleURL = cacheManager.updateBundleUrl,
              let folderURL = cacheManager.updateBundleFolderUrl else {
            LingoHubLogger.shared.log("Could not determine update bundle destination URL.")
            throw LingoHubSDKError.apiError(statusCode: 0, message: "Could not determine storage location", errorCodes: [])
        }

        do {
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
            _ = try await installer.install(archiveURL: archiveURL, liveBundleURL: liveBundleURL, expectedSha256: expectedSha256)
        } catch {
            LingoHubLogger.shared.log("Error installing bundle: \(error)")
            throw LingoHubSDKError.apiError(statusCode: 0, message: "Failed to install bundle: \(error.localizedDescription)", errorCodes: [])
        }

        // Downloaded translations are re-downloadable, keep them out of device backups
        cacheManager.excludeFromBackup(folderURL)

        guard cacheManager.activate(bundleURL: liveBundleURL, distributionVersion: identifier, appVersion: appVersion) else {
            throw LingoHubSDKError.apiError(statusCode: 0, message: "Installed bundle could not be opened", errorCodes: [])
        }

        UserDefaults.standard.set(identifier, forKey: LingoHubConstants.distributionVersion)
        UserDefaults.standard.set(appVersion, forKey: LingoHubConstants.appVersion)

        // The snapshot swap above already cleared all caches, so observers that read
        // localized strings synchronously get content from the new release.
        NotificationCenter.default.post(name: .LingoHubDidUpdateLocalization, object: nil)
        LingoHubLogger.shared.log("Bundle successfully updated to release \(identifier)")
    }
}

// MARK: Internal Helpers

extension LingoHubSDK {
    @objc var isUpdatedBundleUsed: Bool {
        return cacheManager.isUpdateActive
    }

    @objc var updateBundleExists: Bool {
        return cacheManager.updateBundleExists
    }

    @objc var distributionVersion: String? {
        return cacheManager.distributionVersion
    }

    @objc var updateAppVersion: String? {
        return cacheManager.updateAppVersion
    }

    /// The language the SDK is effectively serving: the override if set, otherwise the
    /// system language. Sent to the CDN so request metadata matches lookup behavior.
    var effectiveLanguageCode: String? {
        return language ?? Locale.lingohubLanguageCode
    }

    /// The point in time until which update checks are paused after a 429 response.
    var usageLimitCooldownUntil: Date? {
        let timestamp = UserDefaults.standard.double(forKey: LingoHubConstants.usageCooldownUntil)
        guard timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

    func cleanUp() {
        UserDefaults.standard.removeObject(forKey: LingoHubConstants.distributionVersion)
        UserDefaults.standard.removeObject(forKey: LingoHubConstants.appVersion)
        UserDefaults.standard.removeObject(forKey: LingoHubConstants.usageCooldownUntil)

        cacheManager.deactivate()

        // Use cache manager to get the folder URL for cleanup
        if let folderUrl = cacheManager.updateBundleFolderUrl {
            LingoHubLogger.shared.log("Cleaning up update bundle folder at \(folderUrl.path)")
            try? FileManager.default.removeItem(at: folderUrl)
        } else {
            LingoHubLogger.shared.log("Could not determine update bundle folder URL for cleanup.")
        }
    }

    /// Format a DecodingError into a user-friendly error message
    func formatDecodingError(_ error: DecodingError) -> String {
        switch error {
        case .typeMismatch(let type, let context):
            let path = context.codingPath.map { $0.stringValue }.joined(separator: ".")
            return "Type mismatch at path '\(path)': Expected \(type) but found a different type. \(context.debugDescription)"

        case .valueNotFound(let type, let context):
            let path = context.codingPath.map { $0.stringValue }.joined(separator: ".")
            return "Value of type \(type) not found at path '\(path)'. \(context.debugDescription)"

        case .keyNotFound(let key, let context):
            let path = context.codingPath.map { $0.stringValue }.joined(separator: ".")
            return "Key '\(key.stringValue)' not found at path '\(path)'. \(context.debugDescription)"

        case .dataCorrupted(let context):
            let path = context.codingPath.map { $0.stringValue }.joined(separator: ".")
            return "Data corrupted at path '\(path)'. \(context.debugDescription)"

        @unknown default:
            return "Unknown decoding error: \(error.localizedDescription)"
        }
    }
}

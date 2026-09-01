//
//  LingohubSDK.swift
//
//
//  Created by Manfred Baldauf on 12.03.25.
//

import Foundation
import ZIPFoundation

/**
 Lingohub iOS SDK
 Use this SDK to update your localizable strings without the need of an app update.
 */
@MainActor public final class LingohubSDK {
    /**
     The shared instance of the Lingohub SDK
     */
    public static let shared = LingohubSDK()

    public var environment: Environment = .production

    @objc var apiKey: String?
    @objc var appVersion: String?
    @objc var sdkVersion: String?

    /**
     The language the SDK currently serves. Set via `setLanguage(_:)` / `setSystemLanguage()`.
     */
    @objc public var language: String? {
        get { cacheManager.language }
        set { cacheManager.language = newValue }
    }

    lazy var apiClient = APIClient(basePath: LingohubConstants.basePath)
    let cacheManager = LocalizationCacheManager.shared

    @objc var swizzledBundles: [String] {
        get { cacheManager.swizzledBundlePaths }
        set { cacheManager.swizzledBundlePaths = newValue }
    }

    private var deviceIdentifier: String?
    internal init() {}

}

// MARK: Public Interface

public extension LingohubSDK {
    /**
     Configure the Lingohub SDK. Call this method before any others.

     - Parameter apiKey: Your Lingohub API Key.
     - Parameter appVersion: The version of your app. If nil, the *CFBundleShortVersionString* from the Info.plist File is used.
     - Parameter environment: The environment to use. Default is .production.
     - Parameter logLevel: The log level to use. Default is .none.
     */
    func configure(withApiKey apiKey: String, appVersion: String? = nil, environment: Environment = .production, logLevel: LogLevel = .none) {
        self.apiKey = apiKey
        self.sdkVersion = LingohubConstants.version
        self.deviceIdentifier = Device.identifier
        self.environment = environment
        // Configure the logger's enabled state
        LingohubLogger.shared.logLevel = logLevel

        guard let version = appVersion ?? Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else {
            assertionFailure("Please provide an AppVersion")
            return
        }

        LingohubLogger.shared.log("App version from Info.plist: \(version)")
        LingohubLogger.shared.log("Environment set to: \(environment.rawValue)")

        // Move translations downloaded by SDK 1.0.x from Documents to Application Support
        cacheManager.migrateLegacyStorageIfNeeded()

        // if the app version has changed, remove all updated bundles
        if isUpdatedBundleUsed, let currentVersion = updateAppVersion, currentVersion != version {
            cleanUp()
        }

        // Restore a persisted language override, otherwise use the system language
        language = UserDefaults.standard.string(forKey: LingohubConstants.languageOverride) ?? Locale.lingohubLanguageCode

        self.appVersion = version
    }

    /**
     Override the system language. The override is persisted and restored on the next launch.

     - Parameter language: The ISO 639-1 two letter language code of the language, e.g. 'en' or 'de'
     */
    func setLanguage(_ language: String) {
        self.language = language
        UserDefaults.standard.set(language, forKey: LingohubConstants.languageOverride)
    }

    /**
     Reset the language back to the system language and remove the persisted override.
     */
    func setSystemLanguage() {
        self.language = nil
        UserDefaults.standard.removeObject(forKey: LingohubConstants.languageOverride)
    }

    /**
     Retrieve the updated string.

     - Parameter key: The key of your localization string
     - Parameter tableName: The file where your key is found (default is Localizable.strings)

     - Returns: The updated string or nil
     */
    func localizedString(forKey key: String, tableName: String? = nil) -> String? {
        // Use the cache manager to get the string
        if let string = cacheManager.getString(forKey: key, tableName: tableName, language: language) {
            return string
        }
        return nil

    }

    /**
     Swizzle the main Bundle of your Application.
     If swizzling is enabled just continue using *NSLocalizedString* methods as usual, Lingohub will do the rest.
     */
    func swizzleMainBundle() {
        swizzleBundle(Bundle.main)
    }

    /**
     Swizzle the given bundle, in addition to any bundles that are already swizzled.
     If swizzling is enabled just continue using *NSLocalizedString* methods as usual, Lingohub will do the rest.

     - Parameter bundle: The bundle you want to enable swizzling for
     */
    func swizzleBundle(_ bundle: Bundle) {
        swizzleBundles([bundle])
    }

    /**
     Swizzle the given bundles, in addition to any bundles that are already swizzled.
     If swizzling is enabled just continue using *NSLocalizedString* methods as usual, Lingohub will do the rest.

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
     Check if there are any localization updates available for you app on Lingohub
     Use the result-closure or the `LingohubDidUpdateLocalization` notification as status callback

     - Parameter result: Closure to check for updated content. `True` means the content was updated, `False` that there was no new content.
     */
    func update(result: (@Sendable (Result<Bool, LingohubSDKError>) -> Void)? = nil) {
        checkForUpdate { response in
            DispatchQueue.main.async {
                result?(response)
            }
        }
    }

    /**
     Check if there are any localization updates available for your app on Lingohub,
     using Swift concurrency.

     Named distinctly from `update(result:)` so that existing fire-and-forget
     `update()` calls in async contexts keep compiling unchanged.

     - Returns: `true` if new translations were downloaded and are active, `false` if there was nothing new.
     - Throws: `LingohubSDKError` when the update check fails.
     */
    @discardableResult
    func updateAsync() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            checkForUpdate { result in
                continuation.resume(with: result)
            }
        }
    }
}

// MARK: Public Swift Interface

public extension Notification.Name {
    /**
     Observe this notification to get notified when Lingohub has found updated localizations
     */
    static let LingohubDidUpdateLocalization = Notification.Name(LingohubConstants.updateNotification)
}


@available(swift, obsoleted: 1.0)
@objc public extension NSNotification {
    /**
     Observe this notification to get notified when Lingohub has found updated localizations
     */
    static var LingohubDidUpdateLocalization: NSString {
        return NSString(string: LingohubConstants.updateNotification)
    }
}

public extension LingohubSDK {
    /**
     Check if there are any localization updates available for you app on Lingohub
     Use the result-closure or the `LingohubDidUpdateLocalization` notification as status callback

     - Parameter result: Closure to check for updated content. `True` means the content was updated, `False` that there was no new content.
     */
    func checkForUpdate(result: @escaping @Sendable (Result<Bool, LingohubSDKError>) -> Void) {

        guard let sdkVersion = sdkVersion else {
            LingohubLogger.shared.log("Error: Invalid SDK version")
            result(.failure(LingohubSDKError.invalidSdkVersion))
            return
        }
       LingohubLogger.shared.log("SDK Version: \(sdkVersion)")

        guard let appVersion = appVersion else {
           LingohubLogger.shared.log("Error: Invalid app version")
            result(.failure(LingohubSDKError.invalidAppVersion))
            return
        }
       LingohubLogger.shared.log("App Version: \(appVersion)")

        guard let apiKey = apiKey else {
           LingohubLogger.shared.log("Error: Invalid API key")
            result(.failure(LingohubSDKError.invalidApiKey))
            return
        }

        // After a 429 (usage budget exhausted) the SDK pauses update checks for a while
        // instead of hammering the CDN.
        if let cooldownUntil = usageLimitCooldownUntil, cooldownUntil > Date() {
            LingohubLogger.shared.log("Usage limit cooldown active until \(cooldownUntil), skipping update check")
            result(.failure(LingohubSDKError.apiError(statusCode: 429, message: "Usage limit reached. Update checks are paused until \(cooldownUntil).")))
            return
        }

       LingohubLogger.shared.log("Current Bundle ID: \(distributionVersion ?? "nil")")
       LingohubLogger.shared.log("Environment: \(environment)")
       LingohubLogger.shared.log("Device ID: \(deviceIdentifier ?? "nil")")

        apiClient.checkForUpdates(apiKey: apiKey, appVersion: appVersion, sdkVersion: sdkVersion, distributionVersion: distributionVersion, environment: environment, deviceIdentifier: deviceIdentifier, languageCode: effectiveLanguageCode) { [weak self] response in
            do {
                let bundleInfo = try response()
                LingohubLogger.shared.log("Bundle info received: \(bundleInfo)")

                if let self = self {
                    Task { @MainActor in
                        LingohubLogger.shared.log("Preparing to download update...")
                        // Use the filesUrl field from the API response
                        if let filesUrl = bundleInfo.filesUrl {
                            LingohubLogger.shared.log("Starting download from URL: \(filesUrl)")
                            self.downloadUpdate(atUrl: filesUrl, withIdentifier: bundleInfo.id, appVersion: appVersion, result: result)
                        } else {
                            LingohubLogger.shared.log("Error: No valid URL found in the response")
                            result(.failure(LingohubSDKError.apiError(statusCode: 0, message: "No valid download URL found in the response")))
                        }
                    }
                } else {
                    LingohubLogger.shared.log("Self is nil, cannot proceed with download")
                    result(.success(false))
                }
            } catch APIError.noContent {
                LingohubLogger.shared.log("No content available for update")
                result(.success(false))
            } catch APIError.apiError(404, _, let infos) where infos.contains("DISTRIBUTION_NOT_FOUND") {
                // The CDN's DISTRIBUTION_NOT_FOUND means no release matches this app version
                // and no fallback release exists (e.g. nothing has been published yet).
                // That is a normal state, not an error. Any other 404 stays a failure.
                LingohubLogger.shared.log("No distribution release available for this app (404 DISTRIBUTION_NOT_FOUND)")
                result(.success(false))
            } catch APIError.apiError(let statusCode, let message, _) {
                LingohubLogger.shared.log("API error: Status \(statusCode), Message: \(message ?? "No message")")
                if statusCode == 429 {
                    // Usage budget exhausted; pause update checks client-side.
                    UserDefaults.standard.set(Date().addingTimeInterval(LingohubConstants.usageLimitCooldownInterval).timeIntervalSince1970, forKey: LingohubConstants.usageCooldownUntil)
                }
                result(.failure(LingohubSDKError.apiError(statusCode: statusCode, message: message)))
            } catch let error as DecodingError {
                // Handle decoding errors specifically
                let errorMessage = self?.formatDecodingError(error) ?? "JSON decoding error"
                LingohubLogger.shared.log("Decoding error: \(errorMessage)")
                result(.failure(LingohubSDKError.apiError(statusCode: 0, message: errorMessage)))
            } catch {
                LingohubLogger.shared.log("Unexpected error: \(error)")
                result(.failure(LingohubSDKError.unknown))
            }
        }
    }

    func downloadUpdate(atUrl url: URL, withIdentifier identifier: String, appVersion: String, result: @escaping @Sendable (Result<Bool, LingohubSDKError>) -> Void) {
        LingohubLogger.shared.log("Starting download from URL: \(url.absoluteString)")

        apiClient.download(url: url) { [weak self] response in
            LingohubLogger.shared.log("Download response received")

            guard let self = self else {
                LingohubLogger.shared.log("Self is nil, cannot process download response")
                result(.failure(LingohubSDKError.unknown))
                return
            }

            do {
                let temporaryUrl = try response()
                LingohubLogger.shared.log("Download completed to temporary URL: \(temporaryUrl.path)")

                // Verify the downloaded file exists
                let fileManager = FileManager.default
                guard fileManager.fileExists(atPath: temporaryUrl.path) else {
                    LingohubLogger.shared.log("Error: Downloaded file does not exist at path: \(temporaryUrl.path)")
                    result(.failure(LingohubSDKError.apiError(statusCode: 0, message: "Downloaded file does not exist")))
                    return
                }

                Task { @MainActor in
                    LingohubLogger.shared.log("Starting extraction process...")
                    defer { try? fileManager.removeItem(at: temporaryUrl) }
                    do {
                        try self.useUpdatedBundle(atURL: temporaryUrl, withIdentifier: identifier, appVersion: appVersion)
                        LingohubLogger.shared.log("Bundle successfully updated")
                        result(.success(true))
                    } catch APIError.apiError(let statusCode, let message, _) {
                        LingohubLogger.shared.log("API error during extraction: \(statusCode), \(message ?? "No message")")
                        result(.failure(LingohubSDKError.apiError(statusCode: statusCode, message: message)))
                    } catch {
                        LingohubLogger.shared.log("Error extracting bundle: \(error)")
                        result(.failure(LingohubSDKError.apiError(statusCode: 0, message: "Failed to extract bundle: \(error.localizedDescription)")))
                    }
                }
            } catch APIError.apiError(let statusCode, let message, _) {
                LingohubLogger.shared.log("API error during download: \(statusCode), \(message ?? "No message")")
                result(.failure(LingohubSDKError.apiError(statusCode: statusCode, message: message)))
            } catch {
                LingohubLogger.shared.log("Error downloading bundle: \(error)")
                result(.failure(LingohubSDKError.apiError(statusCode: 0, message: "Failed to download bundle: \(error.localizedDescription)")))
            }
        }
    }

    @MainActor
    @objc func useUpdatedBundle(atURL url: URL, withIdentifier identifier: String, appVersion: String) throws {
        let fileManager = FileManager.default
        // Use the cacheManager to get the destination URL
        guard let destinationURL = cacheManager.updateBundleUrl else {
           LingohubLogger.shared.log("Could not determine update bundle destination URL.")
            throw APIError.invalidURL
        }

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: destinationURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true, attributes: nil)
        try fileManager.removeItem(at: destinationURL)
        try fileManager.unzipItem(at: url, to: destinationURL)

        // Downloaded translations are re-downloadable, keep them out of device backups
        if let folderUrl = cacheManager.updateBundleFolderUrl {
            cacheManager.excludeFromBackup(folderUrl)
        }

        UserDefaults.standard.set(identifier, forKey: LingohubConstants.distributionVersion)
        UserDefaults.standard.set(appVersion, forKey: LingohubConstants.appVersion)
        NotificationCenter.default.post(name: .LingohubDidUpdateLocalization, object: nil)

        // Clear the cache now that the bundle is updated
        cacheManager.clearCache()
       LingohubLogger.shared.log("Localization cache cleared after update.")
    }
}

// MARK: Internal Helpers

extension LingohubSDK {
    @objc var isUpdatedBundleUsed: Bool {
        return cacheManager.isUpdateActive
    }

    @objc public var updateBundleExists: Bool {
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
        let timestamp = UserDefaults.standard.double(forKey: LingohubConstants.usageCooldownUntil)
        guard timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

    func cleanUp() {
        UserDefaults.standard.removeObject(forKey: LingohubConstants.distributionVersion)
        UserDefaults.standard.removeObject(forKey: LingohubConstants.appVersion)
        UserDefaults.standard.removeObject(forKey: LingohubConstants.usageCooldownUntil)

        // Use cache manager to get the folder URL for cleanup
        if let folderUrl = cacheManager.updateBundleFolderUrl {
           LingohubLogger.shared.log("Cleaning up update bundle folder at \(folderUrl.path)")
            try? FileManager.default.removeItem(at: folderUrl)
        } else {
           LingohubLogger.shared.log("Could not determine update bundle folder URL for cleanup.")
        }

        // Also clear the cache
        cacheManager.clearCache()
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

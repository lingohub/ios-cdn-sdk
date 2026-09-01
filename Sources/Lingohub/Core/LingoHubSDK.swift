//
//  LingoHubSDK.swift
//
//
//  Created by Manfred Baldauf on 12.03.25.
//

import Foundation
import ZIPFoundation

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
     The language override set via `setLanguage(_:)`, or `nil` when the SDK follows the
     system language. For the language actually being served, use ``currentLanguageCode``.
     */
    @objc public var language: String? {
        get { cacheManager.language }
        set { cacheManager.language = newValue }
    }

    /**
     The ISO 639-1 code of the language the SDK is currently serving: the override set
     via `setLanguage(_:)`, or the system language when no override is active.
     */
    @objc public var currentLanguageCode: String? {
        return effectiveLanguageCode
    }

    lazy var apiClient = APIClient(basePath: LingoHubConstants.basePath)
    let cacheManager = LocalizationCacheManager.shared

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

        LingoHubLogger.shared.log("App version from Info.plist: \(version)")
        LingoHubLogger.shared.log("Environment set to: \(environment.rawValue)")

        // Move translations downloaded by SDK 1.0.x from Documents to Application Support
        cacheManager.migrateLegacyStorageIfNeeded()

        // if the app version has changed, remove all updated bundles
        if isUpdatedBundleUsed, let currentVersion = updateAppVersion, currentVersion != version {
            cleanUp()
        }

        // Restore a persisted language override, otherwise use the system language
        language = UserDefaults.standard.string(forKey: LingoHubConstants.languageOverride) ?? Locale.lingohubLanguageCode

        self.appVersion = version
    }

    /**
     Override the system language. The override is persisted and restored on the next launch.

     - Parameter language: The ISO 639-1 two letter language code of the language, e.g. 'en' or 'de'
     */
    func setLanguage(_ language: String) {
        self.language = language
        UserDefaults.standard.set(language, forKey: LingoHubConstants.languageOverride)
    }

    /**
     Reset the language back to the system language and remove the persisted override.
     */
    func setSystemLanguage() {
        self.language = nil
        UserDefaults.standard.removeObject(forKey: LingoHubConstants.languageOverride)
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
     If swizzling is enabled just continue using *NSLocalizedString* methods as usual, LingoHub will do the rest.
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

     - Parameter result: Closure to check for updated content. `True` means the content was updated, `False` that there was no new content.
     */
    func update(result: (@Sendable (Result<Bool, LingoHubSDKError>) -> Void)? = nil) {
        checkForUpdate { response in
            DispatchQueue.main.async {
                result?(response)
            }
        }
    }

    /**
     Check if there are any localization updates available for your app on LingoHub,
     using Swift concurrency.

     Named distinctly from `update(result:)` so that existing fire-and-forget
     `update()` calls in async contexts keep compiling unchanged.

     - Returns: `true` if new translations were downloaded and are active, `false` if there was nothing new.
     - Throws: `LingoHubSDKError` when the update check fails.
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

public extension LingoHubSDK {
    /**
     Check if there are any localization updates available for your app on LingoHub
     Use the result-closure or the `LingoHubDidUpdateLocalization` notification as status callback

     - Parameter result: Closure to check for updated content. `True` means the content was updated, `False` that there was no new content.
     */
    func checkForUpdate(result: @escaping @Sendable (Result<Bool, LingoHubSDKError>) -> Void) {

        guard let sdkVersion = sdkVersion else {
            LingoHubLogger.shared.log("Error: Invalid SDK version")
            result(.failure(LingoHubSDKError.invalidSdkVersion))
            return
        }
       LingoHubLogger.shared.log("SDK Version: \(sdkVersion)")

        guard let appVersion = appVersion else {
           LingoHubLogger.shared.log("Error: Invalid app version")
            result(.failure(LingoHubSDKError.invalidAppVersion))
            return
        }
       LingoHubLogger.shared.log("App Version: \(appVersion)")

        guard let apiKey = apiKey else {
           LingoHubLogger.shared.log("Error: Invalid API key")
            result(.failure(LingoHubSDKError.invalidApiKey))
            return
        }

        // After a 429 (usage budget exhausted) the SDK pauses update checks for a while
        // instead of hammering the CDN.
        if let cooldownUntil = usageLimitCooldownUntil, cooldownUntil > Date() {
            LingoHubLogger.shared.log("Usage limit cooldown active until \(cooldownUntil), skipping update check")
            result(.failure(LingoHubSDKError.apiError(statusCode: 429, message: "Usage limit reached. Update checks are paused until \(cooldownUntil).", errorCodes: ["USAGE_LIMIT_EXCEEDED"])))
            return
        }

       LingoHubLogger.shared.log("Current Bundle ID: \(distributionVersion ?? "nil")")
       LingoHubLogger.shared.log("Environment: \(environment)")
       LingoHubLogger.shared.log("Device ID: \(deviceIdentifier ?? "nil")")

        apiClient.checkForUpdates(apiKey: apiKey, appVersion: appVersion, sdkVersion: sdkVersion, distributionVersion: distributionVersion, environment: environment, deviceIdentifier: deviceIdentifier, languageCode: effectiveLanguageCode) { [weak self] response in
            do {
                let bundleInfo = try response()
                LingoHubLogger.shared.log("Bundle info received: \(bundleInfo)")

                if let self = self {
                    Task { @MainActor in
                        LingoHubLogger.shared.log("Preparing to download update...")
                        // Use the filesUrl field from the API response
                        if let filesUrl = bundleInfo.filesUrl {
                            LingoHubLogger.shared.log("Starting download from URL: \(filesUrl)")
                            self.downloadUpdate(atUrl: filesUrl, withIdentifier: bundleInfo.id, appVersion: appVersion, result: result)
                        } else {
                            LingoHubLogger.shared.log("Error: No valid URL found in the response")
                            result(.failure(LingoHubSDKError.apiError(statusCode: 0, message: "No valid download URL found in the response", errorCodes: [])))
                        }
                    }
                } else {
                    LingoHubLogger.shared.log("Self is nil, cannot proceed with download")
                    result(.success(false))
                }
            } catch APIError.noContent {
                LingoHubLogger.shared.log("No content available for update")
                result(.success(false))
            } catch APIError.apiError(404, _, let infos) where infos.contains("DISTRIBUTION_NOT_FOUND") {
                // The CDN's DISTRIBUTION_NOT_FOUND means no release matches this app version
                // and no fallback release exists (e.g. nothing has been published yet).
                // That is a normal state, not an error. Any other 404 stays a failure.
                LingoHubLogger.shared.log("No distribution release available for this app (404 DISTRIBUTION_NOT_FOUND)")
                result(.success(false))
            } catch APIError.apiError(let statusCode, let message, let infos) {
                LingoHubLogger.shared.log("API error: Status \(statusCode), Message: \(message ?? "No message")")
                if statusCode == 429 {
                    // Usage budget exhausted; pause update checks client-side.
                    UserDefaults.standard.set(Date().addingTimeInterval(LingoHubConstants.usageLimitCooldownInterval).timeIntervalSince1970, forKey: LingoHubConstants.usageCooldownUntil)
                }
                result(.failure(LingoHubSDKError.apiError(statusCode: statusCode, message: message, errorCodes: infos)))
            } catch let error as DecodingError {
                // Handle decoding errors specifically
                let errorMessage = self?.formatDecodingError(error) ?? "JSON decoding error"
                LingoHubLogger.shared.log("Decoding error: \(errorMessage)")
                result(.failure(LingoHubSDKError.apiError(statusCode: 0, message: errorMessage, errorCodes: [])))
            } catch let error as URLError {
                // Transport failure before any response was received (offline, DNS, timeout):
                // statusCode 0 per the documented apiError contract.
                LingoHubLogger.shared.log("Network error: \(error.localizedDescription)")
                result(.failure(LingoHubSDKError.apiError(statusCode: 0, message: error.localizedDescription, errorCodes: [])))
            } catch APIError.invalidURL {
                LingoHubLogger.shared.log("Invalid request URL")
                result(.failure(LingoHubSDKError.apiError(statusCode: 0, message: "Invalid request URL", errorCodes: [])))
            } catch APIError.invalidResponse {
                LingoHubLogger.shared.log("Invalid response from the server")
                result(.failure(LingoHubSDKError.apiError(statusCode: 0, message: "Invalid response from the server", errorCodes: [])))
            } catch {
                LingoHubLogger.shared.log("Unexpected error: \(error)")
                result(.failure(LingoHubSDKError.unknown))
            }
        }
    }

    func downloadUpdate(atUrl url: URL, withIdentifier identifier: String, appVersion: String, result: @escaping @Sendable (Result<Bool, LingoHubSDKError>) -> Void) {
        LingoHubLogger.shared.log("Starting download from URL: \(url.absoluteString)")

        apiClient.download(url: url) { [weak self] response in
            LingoHubLogger.shared.log("Download response received")

            guard let self = self else {
                LingoHubLogger.shared.log("Self is nil, cannot process download response")
                result(.failure(LingoHubSDKError.unknown))
                return
            }

            do {
                let temporaryUrl = try response()
                LingoHubLogger.shared.log("Download completed to temporary URL: \(temporaryUrl.path)")

                // Verify the downloaded file exists
                let fileManager = FileManager.default
                guard fileManager.fileExists(atPath: temporaryUrl.path) else {
                    LingoHubLogger.shared.log("Error: Downloaded file does not exist at path: \(temporaryUrl.path)")
                    result(.failure(LingoHubSDKError.apiError(statusCode: 0, message: "Downloaded file does not exist", errorCodes: [])))
                    return
                }

                Task { @MainActor in
                    LingoHubLogger.shared.log("Starting extraction process...")
                    defer { try? fileManager.removeItem(at: temporaryUrl) }
                    do {
                        try self.useUpdatedBundle(atURL: temporaryUrl, withIdentifier: identifier, appVersion: appVersion)
                        LingoHubLogger.shared.log("Bundle successfully updated")
                        result(.success(true))
                    } catch APIError.apiError(let statusCode, let message, let infos) {
                        LingoHubLogger.shared.log("API error during extraction: \(statusCode), \(message ?? "No message")")
                        result(.failure(LingoHubSDKError.apiError(statusCode: statusCode, message: message, errorCodes: infos)))
                    } catch {
                        LingoHubLogger.shared.log("Error extracting bundle: \(error)")
                        result(.failure(LingoHubSDKError.apiError(statusCode: 0, message: "Failed to extract bundle: \(error.localizedDescription)", errorCodes: [])))
                    }
                }
            } catch APIError.apiError(let statusCode, let message, let infos) {
                LingoHubLogger.shared.log("API error during download: \(statusCode), \(message ?? "No message")")
                result(.failure(LingoHubSDKError.apiError(statusCode: statusCode, message: message, errorCodes: infos)))
            } catch {
                LingoHubLogger.shared.log("Error downloading bundle: \(error)")
                result(.failure(LingoHubSDKError.apiError(statusCode: 0, message: "Failed to download bundle: \(error.localizedDescription)", errorCodes: [])))
            }
        }
    }

    @MainActor
    @objc func useUpdatedBundle(atURL url: URL, withIdentifier identifier: String, appVersion: String) throws {
        let fileManager = FileManager.default
        // Use the cacheManager to get the destination URL
        guard let destinationURL = cacheManager.updateBundleUrl else {
           LingoHubLogger.shared.log("Could not determine update bundle destination URL.")
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

        UserDefaults.standard.set(identifier, forKey: LingoHubConstants.distributionVersion)
        UserDefaults.standard.set(appVersion, forKey: LingoHubConstants.appVersion)
        NotificationCenter.default.post(name: .LingoHubDidUpdateLocalization, object: nil)

        // Clear the cache now that the bundle is updated
        cacheManager.clearCache()
       LingoHubLogger.shared.log("Localization cache cleared after update.")
    }
}

// MARK: Internal Helpers

extension LingoHubSDK {
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
        let timestamp = UserDefaults.standard.double(forKey: LingoHubConstants.usageCooldownUntil)
        guard timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

    func cleanUp() {
        UserDefaults.standard.removeObject(forKey: LingoHubConstants.distributionVersion)
        UserDefaults.standard.removeObject(forKey: LingoHubConstants.appVersion)
        UserDefaults.standard.removeObject(forKey: LingoHubConstants.usageCooldownUntil)

        // Use cache manager to get the folder URL for cleanup
        if let folderUrl = cacheManager.updateBundleFolderUrl {
           LingoHubLogger.shared.log("Cleaning up update bundle folder at \(folderUrl.path)")
            try? FileManager.default.removeItem(at: folderUrl)
        } else {
           LingoHubLogger.shared.log("Could not determine update bundle folder URL for cleanup.")
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

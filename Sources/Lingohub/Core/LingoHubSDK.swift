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

    /**
     The minimum time between update checks, in seconds. For this long after the last
     successful update, `update(result:)` and `updateAsync()` report `false` without
     contacting the CDN, so you can call them whenever your app becomes active.

     Defaults to 15 minutes, and to 0 in debug builds so that every call checks while you
     develop. Pauses after failed checks apply regardless of it; see "Failures and
     retries" in the README.
     */
    public var minimumCheckInterval: TimeInterval = UpdatePolicy.defaultMinimumCheckInterval

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

    /// Background merged-bundle work (a launch-time build, removing superseded
    /// bundles), chained so it runs in order. Installs wait for it first, so installs
    /// and merged-bundle work run strictly in order.
    var pendingMergedBundleWork: Task<Void, Never>?

    /// Replaces the time update checks are paced by, so tests move it instead of waiting.
    var clockOverride: (@Sendable () -> Date)?

    /// Replaces the wait before the retry after a 5xx, so tests record it instead of waiting.
    var retryWaitOverride: (@Sendable (TimeInterval) async throws -> Void)?

    /// Client errors already logged in this process (see `logAPIError`).
    private var loggedClientErrors: Set<String> = []

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

        // SDK 1.1 to 2.0 kept the pause after a 429 under a key of its own; the update
        // schedule replaced it
        UserDefaults.standard.removeObject(forKey: LingoHubConstants.legacyUsageCooldownUntil)

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

        // Serve the restored release to `Bundle.lingohub`
        restoreMergedBundle()
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

     Swizzling intercepts `Bundle.localizedString(forKey:value:table:)`, which serves
     `NSLocalizedString` (Swift and Objective-C), storyboards, and XIBs. Swift-native
     lookups (`String(localized:)`, `LocalizedStringResource`,
     `AttributedString(localized:)`, SwiftUI `Text`) never call that method; pass
     ``Foundation/Bundle/lingohub`` to them.

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

     Call it whenever your app becomes active: within ``minimumCheckInterval`` after the
     last successful update, it reports `false` without contacting the CDN, and while a
     failure has paused update checks, it reports that failure the same way (see
     "Failures and retries" in the README).

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

     Within ``minimumCheckInterval`` after the last successful update, it returns
     `false` without contacting the CDN, and while a failure has paused update checks, it
     throws that failure the same way (see "Failures and retries" in the README).

     Cancellation: the shared update cycle itself is never cancelled — once started,
     it always runs to completion so a joined caller's cancellation cannot abort work
     other callers are waiting on. A caller whose task is cancelled is not unblocked
     early; it throws `CancellationError` no later than when the cycle finishes.

     - Returns: `true` if new translations were downloaded and are active, `false` if there was nothing new.
     - Throws: `LingoHubSDKError` when the update check fails; `CancellationError`
       when the calling task was cancelled.
     */
    @discardableResult
    func updateAsync() async throws -> Bool {
        try Task.checkCancellation()
        let result: Bool
        if let inFlightUpdate {
            result = try await inFlightUpdate.value
        } else {
            let task = Task { try await self.performUpdate() }
            inFlightUpdate = task
            defer { inFlightUpdate = nil }
            result = try await task.value
        }
        // Awaiting an unstructured task's value is not interruptible, so surface a
        // cancellation that arrived while waiting now instead of returning a result
        // the caller no longer wants.
        try Task.checkCancellation()
        return result
    }
}

@available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *)
public extension LingoHubSDK {
    /**
     Retargets a `LocalizedStringResource` that looks up your app bundle to
     ``Foundation/Bundle/lingohub``, so it shows downloaded translations wherever a
     `LocalizedStringResource` is accepted:

     ```swift
     Text(LingoHubSDK.shared.resolve("welcome_message"))
     Button(LingoHubSDK.shared.resolve("save_button")) { save() }
     let status = String(localized: LingoHubSDK.shared.resolve("\(unread) unread messages"))
     ```

     Key, table, default value, locale, and interpolation arguments are kept.
     `LocalizedStringResource.bundle` is read-only, so the resource is rebuilt through
     its `Codable` representation. That format is Apple's, not a documented contract,
     which makes this best effort: should it ever stop round-tripping, the resource is
     returned unchanged and shows your bundled strings. Resources that look up another
     bundle (a framework, a Swift package) are returned unchanged, as is every resource
     while no release is active.

     Resolve where the string is used, for example in a view's `body`: the result
     belongs to the release and language active at the time of the call. ``Text(lh:)``
     and ``String(lh:)`` are shorthands for the common cases.
     */
    nonisolated func resolve(_ resource: LocalizedStringResource) -> LocalizedStringResource {
        return LingoHubResourceResolver.resolve(resource, store: cacheManager)
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
    /// Runs one complete update cycle — check → download → verify → install → publish —
    /// paced by the persisted `UpdateSchedule` (see `UpdatePolicy`).
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

        let context = CycleContext(apiKey: apiKey, appVersion: appVersion, sdkVersion: sdkVersion, environment: environment)
        var schedule = UpdateSchedule.load(scope: context.scope)
        switch schedule.decision(at: now, minimumInterval: minimumCheckInterval) {
        case .paused(let cooldown):
            LingoHubLogger.shared.log("Update checks are paused until \(cooldown.until) after HTTP \(cooldown.statusCode), skipping the check")
            throw cooldown.error
        case .skip(let nextCheck):
            LingoHubLogger.shared.log("Last successful update is recent, skipping the check until \(nextCheck)")
            return false
        case .check:
            break
        }

        do {
            let updated = try await runUpdateCycle(context, schedule: &schedule)
            schedule.recordSuccess(at: now)
            persist(schedule, of: context)
            return updated
        } catch {
            // Keeps what the cycle recorded: a pause, or the end of a series of 5xx
            persist(schedule, of: context)
            throw sdkError(for: error)
        }
    }

    /// The configuration an update cycle runs with, captured when it starts. Every
    /// request of the cycle, the install and the schedule use it, even if the app changes
    /// `environment` or calls `configure` again while the cycle waits for its retry.
    private struct CycleContext {
        let apiKey: String
        let appVersion: String
        let sdkVersion: String
        let environment: Environment

        var scope: UpdateSchedule.Scope {
            return UpdateSchedule.Scope(appVersion: appVersion, environment: environment, apiKey: apiKey)
        }
    }

    /// Saves what a cycle recorded, unless the app reconfigured the SDK while it ran: the
    /// schedule then belongs to a scope no longer in use, and saving it would replace the
    /// current scope's schedule.
    private func persist(_ schedule: UpdateSchedule, of context: CycleContext) {
        guard let apiKey, let appVersion,
              context.scope == UpdateSchedule.Scope(appVersion: appVersion, environment: environment, apiKey: apiKey) else {
            LingoHubLogger.shared.log("The SDK was reconfigured during the update check; its schedule is not saved")
            return
        }
        schedule.save()
    }

    /// Checks for a release, downloads and installs it. A download the storage refuses
    /// (an expired URL, a 5xx) gets one fresh check for a new URL; every other failure
    /// ends the cycle, and the next `update()` call is the retry.
    private func runUpdateCycle(_ context: CycleContext, schedule: inout UpdateSchedule) async throws -> Bool {
        guard var release = try await check(context, schedule: &schedule, retryingServerErrors: true) else {
            return false
        }

        let archiveURL: URL
        do {
            archiveURL = try await download(release)
        } catch APIError.apiError(let statusCode, _, _, _) where statusCode > 0 {
            LingoHubLogger.shared.log("Download failed with HTTP \(statusCode), checking again for a fresh download URL")
            guard let freshRelease = try await check(context, schedule: &schedule, retryingServerErrors: false) else {
                return false
            }
            release = freshRelease
            archiveURL = try await download(release)
        }
        defer { try? FileManager.default.removeItem(at: archiveURL) }

        try await installArchive(at: archiveURL, identifier: release.id, appVersion: context.appVersion, expectedSha256: release.filesSha256)
        return true
    }

    /// Sends one check request and applies the policy to the answer. Returns the release
    /// to install, or nil when there is nothing new. A 5xx is retried once when
    /// `retryingServerErrors`; a 5xx that persists, or a 429, pauses update checks.
    private func check(_ context: CycleContext, schedule: inout UpdateSchedule, retryingServerErrors: Bool) async throws -> BundleInfo? {
        LingoHubLogger.shared.log("Checking for updates (release: \(distributionVersion ?? "none"), environment: \(context.environment))")

        do {
            let release = try await apiClient.checkForUpdates(
                apiKey: context.apiKey,
                appVersion: context.appVersion,
                sdkVersion: context.sdkVersion,
                distributionVersion: distributionVersion,
                environment: context.environment,
                deviceIdentifier: deviceIdentifier,
                languageCode: effectiveLanguageCode
            )
            schedule.recordAnswer()
            return release
        } catch APIError.noContent {
            schedule.recordAnswer()
            LingoHubLogger.shared.log("No content available for update")
            return nil
        } catch APIError.apiError(let statusCode, let message, let infos, let retryAfter) {
            switch statusCode {
            case 404 where infos.contains("DISTRIBUTION_NOT_FOUND"):
                // The CDN's DISTRIBUTION_NOT_FOUND means no release matches this app version
                // and no fallback release exists (e.g. nothing has been published yet).
                // That is a normal state, not an error. Any other 404 stays a failure.
                schedule.recordAnswer()
                LingoHubLogger.shared.log("No distribution release available for this app (404 DISTRIBUTION_NOT_FOUND)")
                return nil
            case 429:
                schedule.recordUsageLimit(errorCodes: infos, retryAfter: retryAfter, at: now)
            case 500...599:
                if retryingServerErrors, let delay = UpdatePolicy.serverErrorRetryDelay(retryAfter: retryAfter) {
                    LingoHubLogger.shared.log("Server error (HTTP \(statusCode)), retrying once in \(String(format: "%.1f", delay)) s")
                    try await waitBeforeRetry(delay)
                    return try await check(context, schedule: &schedule, retryingServerErrors: false)
                }
                schedule.recordServerError(statusCode: statusCode, errorCodes: infos, retryAfter: retryAfter, at: now)
            case 1...:
                // No retry: the next update() call checks again
                schedule.recordAnswer()
            default:
                // Status 0: a local failure, the CDN did not answer
                break
            }
            throw APIError.apiError(statusCode: statusCode, message: message, infos: infos, retryAfter: retryAfter)
        }
    }

    /// Downloads a release archive. The caller deletes the returned file.
    private func download(_ release: BundleInfo) async throws -> URL {
        // The CDN is HTTPS-only; a non-HTTPS download URL in the metadata means
        // something between the SDK and the CDN is broken or hostile.
        guard release.filesUrl.scheme?.lowercased() == "https" else {
            LingoHubLogger.shared.log("Rejecting non-HTTPS download URL")
            throw LingoHubSDKError.apiError(statusCode: 0, message: "Insecure download URL rejected", errorCodes: [])
        }
        return try await apiClient.download(from: release.filesUrl, maxSize: installer.limits.maxCompressedSize)
    }

    /// The time update checks are paced by.
    private var now: Date {
        return clockOverride?() ?? Date()
    }

    private func waitBeforeRetry(_ delay: TimeInterval) async throws {
        if let retryWaitOverride {
            try await retryWaitOverride(delay)
        } else {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    /// The `LingoHubSDKError` reported for a failed update cycle.
    private func sdkError(for error: Error) -> LingoHubSDKError {
        switch error {
        case let error as LingoHubSDKError:
            return error
        case APIError.apiError(let statusCode, let message, let infos, _):
            logAPIError(statusCode: statusCode, message: message, infos: infos)
            return .apiError(statusCode: statusCode, message: message, errorCodes: infos)
        case let error as DecodingError:
            let errorMessage = formatDecodingError(error)
            LingoHubLogger.shared.log("Decoding error: \(errorMessage)")
            return .apiError(statusCode: 0, message: errorMessage, errorCodes: [])
        case let error as URLError:
            // Transport failure before any response was received (offline, DNS, timeout):
            // statusCode 0 per the documented apiError contract.
            LingoHubLogger.shared.log("Network error: \(error.localizedDescription)")
            return .apiError(statusCode: 0, message: error.localizedDescription, errorCodes: [])
        case APIError.invalidURL:
            LingoHubLogger.shared.log("Invalid request URL")
            return .apiError(statusCode: 0, message: "Invalid request URL", errorCodes: [])
        case APIError.invalidResponse:
            LingoHubLogger.shared.log("Invalid response from the server")
            return .apiError(statusCode: 0, message: "Invalid response from the server", errorCodes: [])
        default:
            LingoHubLogger.shared.log("Unexpected error: \(error)")
            return .unknown
        }
    }

    /// A client error (400, 401, a 404 other than DISTRIBUTION_NOT_FOUND, …) comes back
    /// on every check until the app or its configuration changes, so each one is logged
    /// once per process.
    private func logAPIError(statusCode: Int, message: String?, infos: [String]) {
        if (400...499).contains(statusCode), statusCode != 429 {
            let signature = "\(statusCode) \(infos.joined(separator: ","))"
            guard loggedClientErrors.insert(signature).inserted else { return }
        }
        LingoHubLogger.shared.log("API error: Status \(statusCode), Message: \(message ?? "No message")")
    }

    /// Installs a downloaded release archive and publishes it:
    /// stage + validate + build the merged bundle + move into a folder of its own (off
    /// the main actor), then — back on the main actor — activate the new snapshot,
    /// persist the release metadata, and notify observers. Observers of
    /// `LingoHubDidUpdateLocalization` always see the new release, through swizzled
    /// lookups and `Bundle.lingohub` alike. The replaced release stays on disk until the
    /// next launch: lookups that resolved it before the swap still read from it, and it
    /// remains the fallback should the new release's metadata not reach disk.
    func installArchive(at archiveURL: URL, identifier: String, appVersion: String, expectedSha256: String? = nil) async throws {
        // Let launch-time merged-bundle work finish first, so installs and merged-bundle
        // work run strictly in order.
        await pendingMergedBundleWork?.value

        // Every release gets a path of its own (see `makeReleaseUrl`)
        guard let releaseURL = cacheManager.makeReleaseUrl(),
              let folderURL = cacheManager.updateBundleFolderUrl else {
            LingoHubLogger.shared.log("Could not determine update bundle destination URL.")
            throw LingoHubSDKError.apiError(statusCode: 0, message: "Could not determine storage location", errorCodes: [])
        }

        let installed: UpdateInstaller.InstallResult
        do {
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
            // The merged bundle is built from the staged release, before the move, so
            // the release and its merged bundle go live together right below.
            installed = try await installer.install(
                archiveURL: archiveURL,
                liveBundleURL: releaseURL,
                expectedSha256: expectedSha256,
                mergedBundle: mergedBundleBuilder(distributionVersion: identifier)
            )
        } catch {
            LingoHubLogger.shared.log("Error installing bundle: \(error)")
            throw LingoHubSDKError.apiError(statusCode: 0, message: "Failed to install bundle: \(error.localizedDescription)", errorCodes: [])
        }
        let mergedBundle = installed.mergedBundle

        // Downloaded translations are re-downloadable, keep them out of device backups
        cacheManager.excludeFromBackup(folderURL)

        guard cacheManager.activate(bundleURL: releaseURL, distributionVersion: identifier, appVersion: appVersion, mergedBundle: mergedBundle) else {
            await installer.removeRelease(at: releaseURL)
            throw LingoHubSDKError.apiError(statusCode: 0, message: "Installed bundle could not be opened", errorCodes: [])
        }

        cacheManager.persistRelease(at: releaseURL, distributionVersion: identifier, appVersion: appVersion)

        // The replaced merged bundle stays until the next launch (see
        // `LocalizationCacheManager.mergedBundlesInUse`).

        // The snapshot swap above already cleared all caches, so observers that read
        // localized strings synchronously get content from the new release.
        NotificationCenter.default.post(name: .LingoHubDidUpdateLocalization, object: nil)
        LingoHubLogger.shared.log("Bundle successfully updated to release \(identifier)")
    }
}

// MARK: Merged Bundle

extension LingoHubSDK {
    /// Makes the release restored at launch available to `Bundle.lingohub`. A merged
    /// bundle an earlier launch built from the same release and the same app tables is
    /// reused synchronously, so the first frame already reads it. Otherwise it is rebuilt
    /// off the main actor and `.LingoHubDidUpdateLocalization` is posted once it is
    /// active; until then `Bundle.lingohub` is `Bundle.main`.
    private func restoreMergedBundle() {
        guard let folderURL = cacheManager.mergedBundlesFolderUrl else { return }

        guard let snapshot = cacheManager.currentSnapshot else {
            // No release: whatever merged bundles are left over belong to a discarded one
            if FileManager.default.fileExists(atPath: folderURL.path) {
                enqueueMergedBundleWork {
                    await self.removeUnusedMergedBundles(in: folderURL)
                }
            }
            return
        }

        let snapshotID = snapshot.id
        let releaseURL = snapshot.bundleURL
        let distributionVersion = snapshot.distributionVersion
        let manifest = MergedBundleManifest(
            distributionVersion: distributionVersion,
            sourceFingerprint: MergedBundleSource(bundle: cacheManager.baseBundle).fingerprint()
        )
        if let mergedBundle = MergedBundle.reusable(matching: manifest, in: folderURL),
           cacheManager.attachMergedBundle(mergedBundle, toSnapshot: snapshotID) {
            LingoHubLogger.shared.log("Merged bundle: reusing \(mergedBundle.url.lastPathComponent)")
            enqueueMergedBundleWork {
                await self.removeUnusedMergedBundles(in: folderURL)
            }
            return
        }

        guard let builder = mergedBundleBuilder(distributionVersion: distributionVersion) else { return }
        enqueueMergedBundleWork { [installer, cacheManager] in
            await self.removeUnusedMergedBundles(in: folderURL)
            let mergedBundle: MergedBundle
            do {
                mergedBundle = try await installer.buildMergedBundle(builder, from: releaseURL)
            } catch {
                // `Bundle.lingohub` keeps serving `Bundle.main`; swizzled lookups are unaffected
                LingoHubLogger.shared.log("Merged bundle: could not build it for release \(distributionVersion): \(error)")
                return
            }
            guard cacheManager.attachMergedBundle(mergedBundle, toSnapshot: snapshotID) else {
                // configure ran again or the release was discarded while this was
                // building: this bundle was never handed out
                await self.removeUnusedMergedBundles(in: folderURL)
                return
            }
            NotificationCenter.default.post(name: .LingoHubDidUpdateLocalization, object: nil)
        }
    }

    /// Removes merged bundles this process never activated: leftovers of earlier
    /// launches and builds that were superseded before being attached. Bundles
    /// activated in this process stay until the next launch (see
    /// `LocalizationCacheManager.mergedBundlesInUse`).
    private func removeUnusedMergedBundles(in folderURL: URL) async {
        await installer.removeMergedBundles(in: folderURL, keeping: cacheManager.mergedBundlesInUse)
    }

    /// Builds merged bundles for `distributionVersion` from the app bundle's tables.
    private func mergedBundleBuilder(distributionVersion: String) -> MergedBundleBuilder? {
        guard let folderURL = cacheManager.mergedBundlesFolderUrl else { return nil }
        return MergedBundleBuilder(
            source: MergedBundleSource(bundle: cacheManager.baseBundle),
            distributionVersion: distributionVersion,
            folder: folderURL
        )
    }

    private func enqueueMergedBundleWork(_ work: @escaping @MainActor @Sendable () async -> Void) {
        let previous = pendingMergedBundleWork
        pendingMergedBundleWork = Task { @MainActor in
            await previous?.value
            await work()
        }
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

    func cleanUp() {
        cacheManager.clearPersistedRelease()
        UpdateSchedule.remove()

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

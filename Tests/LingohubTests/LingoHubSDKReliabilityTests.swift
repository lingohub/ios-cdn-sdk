//
//  LingoHubSDKReliabilityTests.swift
//
//  Facade-level tests for 2.0 behavior: crash healing, update coalescing,
//  notification ordering, language semantics, lookup consistency during
//  activation, and download policy (HTTPS, checksum).
//

import XCTest
@testable import Lingohub
import Mocker

/// Thread-safe box for values captured inside notification blocks or background threads.
private final class CapturedValue<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T?
    var value: T? {
        get { lock.lh_withLock { _value } }
        set { lock.lh_withLock { _value = newValue } }
    }
}

/// An `APIClientProtocol` fake that counts check calls and reports "nothing new",
/// slowly - so concurrent update calls can pile up on one in-flight cycle.
private final class CountingAPIClient: APIClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _checkCount = 0
    var checkCount: Int { lock.lh_withLock { _checkCount } }

    func checkForUpdates(apiKey: String, appVersion: String, sdkVersion: String, distributionVersion: String?, environment: Environment, deviceIdentifier: String?, languageCode: String?) async throws -> BundleInfo {
        lock.lh_withLock { _checkCount += 1 }
        try? await Task.sleep(nanoseconds: 100_000_000)
        throw APIError.noContent
    }

    func download(from url: URL, maxSize: Int64?) async throws -> URL {
        throw APIError.invalidResponse
    }
}

@MainActor
final class LingoHubSDKReliabilityTests: XCTestCase {
    let sut: LingoHubSDK = LingoHubSDK.testInstance()

    private var testStorageRoot: URL!
    /// Scratch space for archives and release directories built by individual tests.
    private var auxDir: URL!

    @MainActor
    override func setUp() async throws {
        try await super.setUp()

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LingohubReliabilityTests-\(UUID().uuidString)")
        testStorageRoot = root
        auxDir = root.appendingPathComponent("aux")
        try FileManager.default.createDirectory(at: auxDir, withIntermediateDirectories: true)
        sut.cacheManager.storageRootOverride = root.appendingPathComponent("current")
        sut.cacheManager.legacyStorageRootOverride = root.appendingPathComponent("legacy")

        sut.reset()
    }

    @MainActor
    override func tearDown() async throws {
        sut.reset()
        Bundle.deswizzle()
        _ = LingoHubSDK.testInstance() // restore the Mocker-backed API client

        try await super.tearDown()

        sut.cacheManager.storageRootOverride = nil
        sut.cacheManager.legacyStorageRootOverride = nil
        try? FileManager.default.removeItem(at: testStorageRoot)
    }

    // MARK: - Language contract

    func testLanguageIsNilAfterConfigure() async throws {
        // `language` is the override; a plain configure must leave it nil while the
        // served language falls back to the system.
        sut.configureForTests()

        XCTAssertNil(sut.language)
        XCTAssertEqual(sut.currentLanguageCode, Locale.lingohubLanguageCode)
    }

    func testLanguagePropertySetterMatchesSetLanguage() async throws {
        sut.configureForTests()

        // Setting the property persists, exactly like setLanguage(_:)
        sut.language = "de"
        XCTAssertEqual(UserDefaults.standard.string(forKey: LingoHubConstants.languageOverride), "de")

        // ... and survives a "relaunch"
        sut.configureForTests()
        XCTAssertEqual(sut.language, "de")

        // nil clears the override, exactly like setSystemLanguage()
        sut.language = nil
        XCTAssertNil(UserDefaults.standard.string(forKey: LingoHubConstants.languageOverride))
        XCTAssertEqual(sut.currentLanguageCode, Locale.lingohubLanguageCode)
    }

    // MARK: - Crash healing

    func testStagingLeftoversRemovedOnConfigure() async throws {
        let folder = try XCTUnwrap(sut.cacheManager.updateBundleFolderUrl)
        let leftover = folder.appendingPathComponent(LingoHubConstants.stagingDirectoryPrefix + "crashed")
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)

        sut.configureForTests()

        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
    }

    func testPersistedMetadataWithoutBundleIsHealed() async throws {
        // A crash between metadata write and a (pre-2.0) partial extraction could
        // leave metadata pointing at nothing. configure must clear it.
        UserDefaults.standard.set("ghost-release", forKey: LingoHubConstants.distributionVersion)
        UserDefaults.standard.set(TestConstants.appVersion, forKey: LingoHubConstants.appVersion)

        sut.configureForTests()

        XCTAssertFalse(sut.isUpdatedBundleUsed)
        XCTAssertNil(UserDefaults.standard.string(forKey: LingoHubConstants.distributionVersion))
        XCTAssertNil(UserDefaults.standard.string(forKey: LingoHubConstants.appVersion))
    }

    func testUnreferencedBundleIsRemovedOnConfigure() async throws {
        let live = try XCTUnwrap(sut.cacheManager.updateBundleUrl)
        try TestArchives.releaseDirectory(strings: ["en": ["K": "orphan"]], at: live)

        sut.configureForTests()

        XCTAssertFalse(sut.isUpdatedBundleUsed)
        XCTAssertFalse(sut.updateBundleExists)
    }

    func testInstalledReleaseSurvivesRelaunch() async throws {
        sut.configureForTests()
        sut.setLanguage("en")
        await sut.installUpdatedBundle()
        XCTAssertTrue(sut.isUpdatedBundleUsed)

        // Simulate the next app launch
        sut.configureForTests()

        XCTAssertTrue(sut.isUpdatedBundleUsed)
        XCTAssertEqual(sut.distributionVersion, TestConstants.bundleIdentifier)
        XCTAssertEqual(sut.localizedString(forKey: "StringPlain"), "String")
    }

    // MARK: - Update coalescing

    func testConcurrentUpdatesShareOneCycle() async throws {
        sut.configureForTests()
        let counting = CountingAPIClient()
        sut.apiClient = counting

        async let first: Bool = sut.updateAsync()
        async let second: Bool = sut.updateAsync()
        let (firstResult, secondResult) = try await (first, second)

        XCTAssertFalse(firstResult)
        XCTAssertFalse(secondResult)
        XCTAssertEqual(counting.checkCount, 1, "Concurrent update calls must share one network round-trip")

        // A later call starts a fresh cycle
        let thirdResult = try await sut.updateAsync()
        XCTAssertFalse(thirdResult)
        XCTAssertEqual(counting.checkCount, 2)
    }

    // MARK: - Notification ordering

    func testNotificationObserverReadsNewRelease() async throws {
        // The documented pattern is "observe the notification, refresh your UI".
        // A synchronous observer must therefore already see the new release.
        sut.configureForTests()
        sut.setLanguage("en")
        await sut.installUpdatedBundle()
        sut.swizzleBundle(Bundle.module)
        // Warm the cache with the old release's value
        XCTAssertEqual(sut.localizedString(forKey: "StringPlain"), "String")

        let secondRelease = auxDir.appendingPathComponent("second.zip")
        try TestArchives.localizationZip(strings: ["en": ["StringPlain": "String v2"]], to: secondRelease)

        let observed = CapturedValue<String>()
        // queue nil: the block runs synchronously on the posting thread
        let token = NotificationCenter.default.addObserver(forName: .LingoHubDidUpdateLocalization, object: nil, queue: nil) { _ in
            observed.value = LocalizationCacheManager.shared.getString(forKey: "StringPlain", tableName: nil, language: "en")
        }
        defer { NotificationCenter.default.removeObserver(token) }

        try await sut.installArchive(at: secondRelease, identifier: "second-release", appVersion: TestConstants.appVersion)

        XCTAssertEqual(observed.value, "String v2", "Observers must never see the previous release's cached strings")
        XCTAssertEqual(sut.distributionVersion, "second-release")
    }

    // MARK: - Fallback semantics

    func testValueFallbackPrefersAppBundleTranslation() async throws {
        // "OnlyInAppBundle" exists in the app (test) bundle but not in the downloaded
        // release. A caller-provided `value:` must not shadow the app translation.
        sut.configureForTests()
        sut.setLanguage("en")
        await sut.installUpdatedBundle()
        sut.swizzleBundle(Bundle.module)

        let value = NSLocalizedString("OnlyInAppBundle", tableName: nil, bundle: Bundle.module, value: "Hardcoded default", comment: "")

        XCTAssertEqual(value, "App bundle value")
    }

    // MARK: - Lookup consistency during activation

    func testLookupsDuringActivationAreConsistent() async throws {
        // While releases are swapped, every lookup must resolve against exactly one
        // release - old or new - never a mix, never a transient miss.
        let releaseA = auxDir.appendingPathComponent("releaseA")
        let releaseB = auxDir.appendingPathComponent("releaseB")
        try TestArchives.releaseDirectory(strings: ["en": ["K": "A"]], at: releaseA)
        try TestArchives.releaseDirectory(strings: ["en": ["K": "B"]], at: releaseB)

        let store = LocalizationCacheManager.shared
        store.activate(bundleURL: releaseA, distributionVersion: "A", appVersion: "1")

        DispatchQueue.concurrentPerform(iterations: 400) { i in
            if i % 40 == 0 {
                let useA = (i / 40) % 2 == 0
                store.activate(bundleURL: useA ? releaseA : releaseB, distributionVersion: useA ? "A" : "B", appVersion: "1")
            } else {
                let value = store.getString(forKey: "K", tableName: nil, language: "en")
                XCTAssertTrue(value == "A" || value == "B", "Unexpected value during activation: \(String(describing: value))")
            }
        }

        // A lookup that raced an activation must not have poisoned the final
        // release's cache with a table loaded from the previous release.
        store.activate(bundleURL: releaseB, distributionVersion: "B", appVersion: "1")
        XCTAssertEqual(store.getString(forKey: "K", tableName: nil, language: "en"), "B")

        store.deactivate()
    }

    // MARK: - Cancellation semantics

    func testCancelledWaiterThrowsCancellationErrorWithoutAbortingCycle() async throws {
        sut.configureForTests()
        let counting = CountingAPIClient()
        sut.apiClient = counting

        let first = Task { try await sut.updateAsync() }
        // Let the shared cycle start, then join it and cancel the joined waiter mid-flight
        try await Task.sleep(nanoseconds: 20_000_000)
        let waiter = Task { try await sut.updateAsync() }
        try await Task.sleep(nanoseconds: 10_000_000)
        waiter.cancel()

        do {
            _ = try await waiter.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // Documented contract: a cancelled caller throws CancellationError no
            // later than when the shared cycle finishes.
        }

        // The shared cycle itself was not aborted by the waiter's cancellation
        let firstResult = try await first.value
        XCTAssertFalse(firstResult)
        XCTAssertEqual(counting.checkCount, 1)
    }

    // MARK: - Transfer policy

    func testDownloadSizeLimitAbortsTransfer() async throws {
        MockService.mockBundleDownload200()
        let configuration = URLSessionConfiguration.default
        configuration.protocolClasses = [MockingURLProtocol.self]
        let client = APIClient(basePath: LingoHubConstants.basePath, configuration: configuration)

        do {
            _ = try await client.download(from: URL(string: "https://s3.amazon.de/update.zip")!, maxSize: 16)
            XCTFail("Expected the download to be rejected")
        } catch APIError.apiError(let statusCode, let message, _) {
            XCTAssertEqual(statusCode, 0)
            XCTAssertEqual(message, "Download exceeded the size limit")
        }
    }

    func testRedirectGuardRefusesNonHTTPSRedirect() async throws {
        let guardDelegate = DownloadGuardDelegate()
        let session = URLSession.shared
        let task = session.downloadTask(with: URL(string: "https://cdn.example/archive.zip")!)
        defer { task.cancel() }
        let redirect = try XCTUnwrap(HTTPURLResponse(url: URL(string: "https://cdn.example/archive.zip")!, statusCode: 302, httpVersion: nil, headerFields: nil))

        // https → http downgrade is refused
        var followed: URLRequest? = URLRequest(url: URL(string: "https://placeholder.invalid")!)
        guardDelegate.urlSession(session, task: task, willPerformHTTPRedirection: redirect, newRequest: URLRequest(url: URL(string: "http://attacker.example/archive.zip")!)) { request in
            followed = request
        }
        XCTAssertNil(followed)
        XCTAssertTrue(guardDelegate.refusedInsecureRedirect)

        // https → https is followed
        let secureTarget = URLRequest(url: URL(string: "https://cdn2.example/archive.zip")!)
        var followedSecure: URLRequest?
        guardDelegate.urlSession(session, task: task, willPerformHTTPRedirection: redirect, newRequest: secureTarget) { request in
            followedSecure = request
        }
        XCTAssertEqual(followedSecure?.url, secureTarget.url)
    }

    // MARK: - Download policy

    func testInsecureDownloadUrlRejected() async throws {
        sut.configureForTests()
        MockService.mockUpdate200(filesUrl: "http://s3.amazon.de/update.zip")

        do {
            _ = try await sut.updateAsync()
            XCTFail("Expected the update to fail")
        } catch LingoHubSDKError.apiError(let statusCode, let message, let errorCodes) {
            XCTAssertEqual(statusCode, 0)
            XCTAssertEqual(message, "Insecure download URL rejected")
            XCTAssertEqual(errorCodes, [])
        }
    }

    func testChecksumVerifiedEndToEnd() async throws {
        sut.configureForTests()
        let sha256 = try TestArchives.sha256Hex(of: TestConstants.updateBundleURL)
        MockService.mockUpdate200(filesUrl: "https://s3.amazon.de/update.zip", sha256: sha256)
        MockService.mockBundleDownload200()

        let updated = try await sut.updateAsync()

        XCTAssertTrue(updated)
        XCTAssertEqual(sut.distributionVersion, TestConstants.bundleIdentifier)
    }

    func testChecksumMismatchFailsUpdate() async throws {
        sut.configureForTests()
        MockService.mockUpdate200(filesUrl: "https://s3.amazon.de/update.zip", sha256: String(repeating: "0", count: 64))
        MockService.mockBundleDownload200()

        do {
            _ = try await sut.updateAsync()
            XCTFail("Expected the update to fail")
        } catch LingoHubSDKError.apiError(let statusCode, let message, _) {
            XCTAssertEqual(statusCode, 0)
            XCTAssertTrue(message?.contains("checksum") == true, "Unexpected message: \(String(describing: message))")
        }

        XCTAssertFalse(sut.isUpdatedBundleUsed)
    }
}

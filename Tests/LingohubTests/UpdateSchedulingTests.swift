//
//  UpdateSchedulingTests.swift
//
//  The "Failures and retries" policy end to end through the SDK facade
//  (lingohub/organization#2351): minimum interval, the single retry after a 5xx,
//  pauses that survive relaunches, and the fresh check after a failed download.
//

import XCTest
@testable import Lingohub
import Mocker

/// A clock tests move forward instead of waiting.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.lh_withLock { _now } }

    func advance(by interval: TimeInterval) {
        lock.lh_withLock { _now += interval }
    }
}

/// The waits the SDK asked for before its retries, recorded instead of waited.
private final class RecordedWaits: @unchecked Sendable {
    private let lock = NSLock()
    private var _delays: [TimeInterval] = []
    var delays: [TimeInterval] { lock.lh_withLock { _delays } }

    func record(_ delay: TimeInterval) {
        lock.lh_withLock { _delays.append(delay) }
    }
}

@MainActor
final class UpdateSchedulingTests: XCTestCase {
    let sut: LingoHubSDK = LingoHubSDK.testInstance()

    private let minute: TimeInterval = 60
    private var testStorageRoot: URL!
    private var clock: TestClock!
    private var waits: RecordedWaits!

    @MainActor
    override func setUp() async throws {
        try await super.setUp()

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LingohubSchedulingTests-\(UUID().uuidString)")
        testStorageRoot = root
        sut.cacheManager.storageRootOverride = root.appendingPathComponent("current")
        sut.cacheManager.legacyStorageRootOverride = root.appendingPathComponent("legacy")
        sut.reset()

        let clock = TestClock()
        let waits = RecordedWaits()
        self.clock = clock
        self.waits = waits
        sut.clockOverride = { clock.now }
        sut.retryWaitOverride = { waits.record($0) }
        // The release default; tests run as a debug build, where it is 0
        sut.minimumCheckInterval = UpdatePolicy.releaseMinimumCheckInterval
        sut.configureForTests()
    }

    @MainActor
    override func tearDown() async throws {
        sut.reset()
        _ = LingoHubSDK.testInstance() // restore the Mocker-backed API client

        try await super.tearDown()

        sut.cacheManager.storageRootOverride = nil
        sut.cacheManager.legacyStorageRootOverride = nil
        try? FileManager.default.removeItem(at: testStorageRoot)
    }

    private func script(checks: [ScriptedAPIClient.CheckAnswer], downloads: [ScriptedAPIClient.DownloadAnswer] = []) -> ScriptedAPIClient {
        let api = ScriptedAPIClient(checks: checks, downloads: downloads)
        sut.apiClient = api
        return api
    }

    private var schedule: UpdateSchedule {
        return sut.storedUpdateSchedule
    }

    /// Simulates the next app launch: nothing survives but what is on disk.
    private func relaunch() {
        sut.configureForTests()
    }

    private func assertUpdateFails(statusCode: Int, errorCodes: [String]? = nil, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            let updated = try await sut.updateAsync()
            XCTFail("Expected the update to fail, got \(updated)", file: file, line: line)
        } catch LingoHubSDKError.apiError(let actualStatusCode, _, let actualErrorCodes) {
            XCTAssertEqual(actualStatusCode, statusCode, file: file, line: line)
            if let errorCodes {
                XCTAssertEqual(actualErrorCodes, errorCodes, file: file, line: line)
            }
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

    // MARK: - Minimum interval

    func testMinimumIntervalSkipsChecksAfterASuccessfulUpdateAcrossRelaunches() async throws {
        let api = script(checks: [ScriptedAPIClient.noContent, ScriptedAPIClient.noContent])

        let first = try await sut.updateAsync()
        XCTAssertFalse(first)
        XCTAssertEqual(api.checkCount, 1)

        relaunch()
        clock.advance(by: 15 * minute - 1)
        let skipped = try await sut.updateAsync()
        XCTAssertFalse(skipped)
        XCTAssertEqual(api.checkCount, 1, "Within the minimum interval, update() does not contact the CDN")

        clock.advance(by: 1)
        let second = try await sut.updateAsync()
        XCTAssertFalse(second)
        XCTAssertEqual(api.checkCount, 2)
    }

    func testInstalledReleaseAndNothingPublishedStartTheMinimumInterval() async throws {
        let api = script(
            checks: [ScriptedAPIClient.release(), .failure(ScriptedAPIClient.httpError(404, infos: ["DISTRIBUTION_NOT_FOUND"]))],
            downloads: [try ScriptedAPIClient.archive()]
        )

        let installed = try await sut.updateAsync()
        XCTAssertTrue(installed)
        XCTAssertEqual(sut.distributionVersion, TestConstants.bundleIdentifier)
        let skipped = try await sut.updateAsync()
        XCTAssertFalse(skipped)
        XCTAssertEqual(api.checkCount, 1)

        clock.advance(by: 15 * minute)
        let nothingPublished = try await sut.updateAsync()
        XCTAssertFalse(nothingPublished)
        let skippedAgain = try await sut.updateAsync()
        XCTAssertFalse(skippedAgain)
        XCTAssertEqual(api.checkCount, 2, "DISTRIBUTION_NOT_FOUND is a successful check")
    }

    func testMinimumIntervalOfZeroChecksOnEveryCall() async throws {
        sut.minimumCheckInterval = 0
        let api = script(checks: [ScriptedAPIClient.noContent, ScriptedAPIClient.noContent])

        _ = try await sut.updateAsync()
        _ = try await sut.updateAsync()

        XCTAssertEqual(api.checkCount, 2)
    }

    // MARK: - Transport errors

    func testTransportErrorIsNotRetriedAndTheNextCallChecksAgain() async throws {
        let api = script(checks: [.failure(URLError(.notConnectedToInternet)), ScriptedAPIClient.noContent])

        await assertUpdateFails(statusCode: 0, errorCodes: [])
        XCTAssertEqual(api.checkCount, 1)
        XCTAssertEqual(waits.delays, [])

        let next = try await sut.updateAsync()
        XCTAssertFalse(next)
        XCTAssertEqual(api.checkCount, 2, "A failure does not start the minimum interval")
    }

    // MARK: - 5xx

    func testServerErrorIsRetriedOnceAfterTwoToFiveSeconds() async throws {
        let api = script(checks: [.failure(ScriptedAPIClient.httpError(503)), ScriptedAPIClient.noContent])

        let updated = try await sut.updateAsync()

        XCTAssertFalse(updated)
        XCTAssertEqual(api.checkCount, 2)
        XCTAssertEqual(waits.delays.count, 1)
        XCTAssertTrue((2...5).contains(waits.delays[0]), "\(waits.delays)")
        XCTAssertNil(schedule.cooldown)
    }

    func testServerErrorRetryFollowsRetryAfter() async throws {
        let api = script(checks: [.failure(ScriptedAPIClient.httpError(503, retryAfter: 4)), ScriptedAPIClient.noContent])

        _ = try await sut.updateAsync()

        XCTAssertEqual(api.checkCount, 2)
        XCTAssertEqual(waits.delays, [4])
    }

    func testPersistentServerErrorPausesChecksWithBackoffAcrossRelaunches() async throws {
        let api = script(checks: [
            .failure(ScriptedAPIClient.httpError(503)), .failure(ScriptedAPIClient.httpError(503)),
            .failure(ScriptedAPIClient.httpError(502)), .failure(ScriptedAPIClient.httpError(502)),
            ScriptedAPIClient.noContent
        ])

        await assertUpdateFails(statusCode: 503)
        XCTAssertEqual(api.checkCount, 2, "One retry, not more")
        XCTAssertEqual(schedule.cooldown?.until, clock.now + 5 * minute)

        // Paused, also after a relaunch: the pause is reported without a request
        relaunch()
        clock.advance(by: 5 * minute - 1)
        await assertUpdateFails(statusCode: 503)
        XCTAssertEqual(api.checkCount, 2)

        // The second failed update in a row pauses for 10 minutes
        clock.advance(by: 1)
        await assertUpdateFails(statusCode: 502)
        XCTAssertEqual(api.checkCount, 4)
        XCTAssertEqual(schedule.cooldown?.until, clock.now + 10 * minute)
        clock.advance(by: 10 * minute - 1)
        await assertUpdateFails(statusCode: 502)
        XCTAssertEqual(api.checkCount, 4)

        // An answer ends the series
        clock.advance(by: 1)
        let recovered = try await sut.updateAsync()
        XCTAssertFalse(recovered)
        XCTAssertEqual(api.checkCount, 5)
        XCTAssertEqual(schedule.consecutiveServerErrors, 0)
        XCTAssertNil(schedule.cooldown)
    }

    func testServerErrorPauseFollowsALongerRetryAfter() async throws {
        let start = clock.now
        let api = script(checks: [
            .failure(ScriptedAPIClient.httpError(503, retryAfter: 2)),
            .failure(ScriptedAPIClient.httpError(503, retryAfter: 2 * 60 * minute))
        ])

        await assertUpdateFails(statusCode: 503)

        XCTAssertEqual(api.checkCount, 2)
        XCTAssertEqual(schedule.cooldown?.until, start + 2 * 60 * minute)
    }

    func testRetryAfterOverTenSecondsSkipsTheRetryAndPausesChecks() async throws {
        let start = clock.now
        let api = script(checks: [.failure(ScriptedAPIClient.httpError(503, retryAfter: 30 * minute))])

        await assertUpdateFails(statusCode: 503)

        XCTAssertEqual(api.checkCount, 1)
        XCTAssertEqual(waits.delays, [])
        XCTAssertEqual(schedule.cooldown?.until, start + 30 * minute)
    }

    // MARK: - 429

    func testUsageLimitPausesChecksForAnHourAcrossRelaunches() async throws {
        let api = script(checks: [
            .failure(ScriptedAPIClient.httpError(429, infos: ["USAGE_LIMIT_EXCEEDED"])),
            ScriptedAPIClient.noContent
        ])

        await assertUpdateFails(statusCode: 429, errorCodes: ["USAGE_LIMIT_EXCEEDED"])
        XCTAssertEqual(api.checkCount, 1, "A 429 is not retried")
        XCTAssertEqual(waits.delays, [])

        relaunch()
        clock.advance(by: 60 * minute - 1)
        await assertUpdateFails(statusCode: 429, errorCodes: ["USAGE_LIMIT_EXCEEDED"])
        XCTAssertEqual(api.checkCount, 1, "No check within the pause")

        clock.advance(by: 1)
        let resumed = try await sut.updateAsync()
        XCTAssertFalse(resumed)
        XCTAssertEqual(api.checkCount, 2)
    }

    func testUsageLimitPauseFollowsALongerRetryAfter() async throws {
        let start = clock.now
        _ = script(checks: [.failure(ScriptedAPIClient.httpError(429, infos: ["USAGE_LIMIT_EXCEEDED"], retryAfter: 3 * 60 * minute))])

        await assertUpdateFails(statusCode: 429)

        XCTAssertEqual(schedule.cooldown?.until, start + 3 * 60 * minute)
    }

    func testNewAppVersionChecksDespiteAPause() async throws {
        let api = script(checks: [
            .failure(ScriptedAPIClient.httpError(429, infos: ["USAGE_LIMIT_EXCEEDED"])),
            ScriptedAPIClient.noContent
        ])
        await assertUpdateFails(statusCode: 429)

        sut.configure(withApiKey: TestConstants.apiKey, appVersion: TestConstants.updatedAppVersion)
        let updated = try await sut.updateAsync()

        XCTAssertFalse(updated)
        XCTAssertEqual(api.checkCount, 2)
    }

    func testAnotherEnvironmentOrCDNKeyChecksDespiteTheIntervalAndAPause() async throws {
        let api = script(checks: [
            ScriptedAPIClient.noContent,
            .failure(ScriptedAPIClient.httpError(429, infos: ["USAGE_LIMIT_EXCEEDED"])),
            ScriptedAPIClient.noContent,
            ScriptedAPIClient.noContent
        ])

        // A successful production check starts the minimum interval
        _ = try await sut.updateAsync()

        // Staging is checked all the same, and its 429 pauses staging
        sut.environment = .staging
        await assertUpdateFails(statusCode: 429)
        XCTAssertEqual(api.checkCount, 2)

        // Another CDN key is checked despite that pause
        sut.configure(withApiKey: "lh-cdn_another-key", appVersion: TestConstants.appVersion, environment: .staging)
        let anotherKey = try await sut.updateAsync()
        XCTAssertFalse(anotherKey)
        XCTAssertEqual(api.checkCount, 3)

        // As is the next environment switch, while the interval of the last one runs
        sut.environment = .production
        let production = try await sut.updateAsync()
        XCTAssertFalse(production)
        XCTAssertEqual(api.checkCount, 4)
    }

    // MARK: - Client errors

    func testClientErrorIsNeitherRetriedNorPaused() async throws {
        let api = script(checks: [
            .failure(ScriptedAPIClient.httpError(401, infos: ["CDN_KEY_NOT_FOUND"])),
            .failure(ScriptedAPIClient.httpError(401, infos: ["CDN_KEY_NOT_FOUND"]))
        ])

        await assertUpdateFails(statusCode: 401, errorCodes: ["CDN_KEY_NOT_FOUND"])
        XCTAssertEqual(api.checkCount, 1)
        XCTAssertEqual(waits.delays, [])
        XCTAssertNil(schedule.cooldown)

        await assertUpdateFails(statusCode: 401, errorCodes: ["CDN_KEY_NOT_FOUND"])
        XCTAssertEqual(api.checkCount, 2, "The next call checks again")
    }

    // MARK: - Downloads

    func testFailedDownloadGetsOneFreshCheckForANewURL() async throws {
        let api = script(
            checks: [
                ScriptedAPIClient.release(filesUrl: "https://s3.amazon.de/update.zip?expired"),
                ScriptedAPIClient.release(filesUrl: "https://s3.amazon.de/update.zip?fresh")
            ],
            downloads: [.failure(ScriptedAPIClient.httpError(403)), try ScriptedAPIClient.archive()]
        )

        let updated = try await sut.updateAsync()

        XCTAssertTrue(updated)
        XCTAssertEqual(api.checkCount, 2)
        XCTAssertEqual(api.downloadedURLs.map(\.query), ["expired", "fresh"])
        XCTAssertEqual(sut.distributionVersion, TestConstants.bundleIdentifier)
    }

    func testDownloadThatFailsAgainGivesUpUntilTheNextCall() async throws {
        let api = script(
            checks: [ScriptedAPIClient.release(), ScriptedAPIClient.release(), ScriptedAPIClient.noContent],
            downloads: [.failure(ScriptedAPIClient.httpError(403)), .failure(ScriptedAPIClient.httpError(503))]
        )

        await assertUpdateFails(statusCode: 503)
        XCTAssertEqual(api.checkCount, 2)
        XCTAssertEqual(api.downloadedURLs.count, 2)
        XCTAssertNil(schedule.cooldown, "A storage failure does not pause checks")

        let next = try await sut.updateAsync()
        XCTAssertFalse(next)
        XCTAssertEqual(api.checkCount, 3)
    }

    func testFreshCheckAfterAFailedDownloadIsNotRetried() async throws {
        let api = script(
            checks: [ScriptedAPIClient.release(), .failure(ScriptedAPIClient.httpError(503))],
            downloads: [.failure(ScriptedAPIClient.httpError(403))]
        )

        await assertUpdateFails(statusCode: 503)

        XCTAssertEqual(api.checkCount, 2)
        XCTAssertEqual(waits.delays, [])
        XCTAssertEqual(schedule.cooldown?.statusCode, 503)
    }

    func testTransportErrorDuringDownloadIsNotRetried() async throws {
        let api = script(
            checks: [ScriptedAPIClient.release()],
            downloads: [.failure(URLError(.networkConnectionLost))]
        )

        await assertUpdateFails(statusCode: 0)

        XCTAssertEqual(api.checkCount, 1)
        XCTAssertEqual(api.downloadedURLs.count, 1)
    }

    // MARK: - Over the wire

    func testRetryAfterHeaderReachesThePolicy() async throws {
        let start = clock.now
        _ = LingoHubSDK.testInstance() // the Mocker-backed API client
        let mock = Mock(
            url: URL(string: LingoHubConstants.basePath + "v1/distributions/check")!,
            ignoreQuery: true,
            contentType: .json,
            statusCode: 429,
            data: [.post: Data(#"{"status": 429, "detail": "Too Many Requests", "errors": [{"field": "USAGE", "infos": ["USAGE_LIMIT_EXCEEDED"]}]}"#.utf8)],
            additionalHeaders: ["Retry-After": "7200"]
        )
        mock.register()

        await assertUpdateFails(statusCode: 429, errorCodes: ["USAGE_LIMIT_EXCEEDED"])

        XCTAssertEqual(schedule.cooldown?.until, start + 2 * 60 * minute)
    }
}

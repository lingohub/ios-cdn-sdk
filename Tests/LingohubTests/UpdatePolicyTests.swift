//
//  UpdatePolicyTests.swift
//
//  The retry and pause policy for update checks (lingohub/organization#2351), its
//  persisted schedule, and Retry-After parsing, without networking.
//

import XCTest
@testable import Lingohub

final class UpdatePolicyTests: XCTestCase {
    private let minute: TimeInterval = 60
    private let hour: TimeInterval = 60 * 60
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let scope = UpdateSchedule.Scope(appVersion: "1.0.0", environment: .production, apiKey: "lh-cdn_key")

    override func tearDown() {
        UpdateSchedule.remove()
        super.tearDown()
    }

    // MARK: - Retry after a 5xx

    func testRetryDelayWithoutRetryAfterIsDrawnFromTwoToFiveSeconds() {
        XCTAssertEqual(UpdatePolicy.serverErrorRetryDelay(retryAfter: nil, randomFraction: 0), 2)
        XCTAssertEqual(UpdatePolicy.serverErrorRetryDelay(retryAfter: nil, randomFraction: 0.5), 3.5)
        XCTAssertEqual(UpdatePolicy.serverErrorRetryDelay(retryAfter: nil, randomFraction: 1), 5)
        XCTAssertEqual(UpdatePolicy.serverErrorRetryDelay(retryAfter: nil, randomFraction: 7), 5, "Out-of-range fractions are clamped")

        for _ in 0..<1000 {
            let delay = UpdatePolicy.serverErrorRetryDelay(retryAfter: nil)
            XCTAssertTrue(delay.map { (2...5).contains($0) } ?? false, "\(String(describing: delay))")
        }
    }

    func testRetryDelayFollowsRetryAfterUpToTenSeconds() {
        XCTAssertEqual(UpdatePolicy.serverErrorRetryDelay(retryAfter: 0), 0)
        XCTAssertEqual(UpdatePolicy.serverErrorRetryDelay(retryAfter: 3), 3)
        XCTAssertEqual(UpdatePolicy.serverErrorRetryDelay(retryAfter: 10), 10)
        XCTAssertNil(UpdatePolicy.serverErrorRetryDelay(retryAfter: 11), "A longer Retry-After skips the retry")
    }

    // MARK: - Pauses

    func testServerErrorPauseDoublesFromFiveMinutesUpToAnHour() {
        let pauses = (1...7).map { UpdatePolicy.serverErrorCooldown(consecutiveFailures: $0, retryAfter: nil) }
        XCTAssertEqual(pauses, [5, 10, 20, 40, 60, 60, 60].map { $0 * minute })
        XCTAssertEqual(UpdatePolicy.serverErrorCooldown(consecutiveFailures: .max, retryAfter: nil), hour)
    }

    func testServerErrorPauseIsNeverShorterThanRetryAfter() {
        XCTAssertEqual(UpdatePolicy.serverErrorCooldown(consecutiveFailures: 1, retryAfter: 3), 5 * minute)
        XCTAssertEqual(UpdatePolicy.serverErrorCooldown(consecutiveFailures: 1, retryAfter: 2 * hour), 2 * hour)
        XCTAssertEqual(UpdatePolicy.serverErrorCooldown(consecutiveFailures: 1, retryAfter: 1_000 * hour), 24 * hour)
    }

    func testUsageLimitPausesForAnHourOrLongerRetryAfter() {
        XCTAssertEqual(UpdatePolicy.usageLimitCooldown(retryAfter: nil), hour)
        XCTAssertEqual(UpdatePolicy.usageLimitCooldown(retryAfter: 5 * minute), hour)
        XCTAssertEqual(UpdatePolicy.usageLimitCooldown(retryAfter: 3 * hour), 3 * hour)
        XCTAssertEqual(UpdatePolicy.usageLimitCooldown(retryAfter: 1_000 * hour), 24 * hour)
    }

    func testDefaultMinimumIntervalIsZeroInDebugBuilds() {
        // The test target is a debug build; release builds use 15 minutes
        XCTAssertEqual(UpdatePolicy.defaultMinimumCheckInterval, 0)
        XCTAssertEqual(UpdatePolicy.releaseMinimumCheckInterval, 15 * minute)
    }

    // MARK: - Schedule decisions

    func testMinimumIntervalCountsFromTheLastSuccessfulUpdate() {
        var schedule = UpdateSchedule(scope: scope)
        XCTAssertEqual(schedule.decision(at: start, minimumInterval: 15 * minute), .check)

        schedule.recordSuccess(at: start)

        XCTAssertEqual(schedule.decision(at: start + 14 * minute, minimumInterval: 15 * minute), .skip(until: start + 15 * minute))
        XCTAssertEqual(schedule.decision(at: start + 15 * minute, minimumInterval: 15 * minute), .check)
        XCTAssertEqual(schedule.decision(at: start + 1, minimumInterval: 0), .check)
        XCTAssertEqual(schedule.decision(at: start + 1, minimumInterval: -5), .check)
        XCTAssertEqual(schedule.decision(at: start + 1, minimumInterval: .infinity), .skip(until: start + .infinity))
    }

    func testClockTurnedBackDoesNotHoldUpdates() {
        var schedule = UpdateSchedule(scope: scope)
        schedule.recordSuccess(at: start)
        XCTAssertEqual(schedule.decision(at: start - hour, minimumInterval: 15 * minute), .check)

        var paused = UpdateSchedule(scope: scope)
        paused.recordUsageLimit(errorCodes: [], retryAfter: nil, at: start)
        XCTAssertEqual(paused.decision(at: start - 2 * hour, minimumInterval: 0), .paused(paused.cooldown!), "Within the longest pause the SDK sets")
        XCTAssertEqual(paused.decision(at: start - 24 * hour, minimumInterval: 0), .check, "Further out than any pause the SDK sets")
    }

    func testServerErrorsPauseWithBackoffUntilTheCDNAnswersAgain() throws {
        var schedule = UpdateSchedule(scope: scope)

        schedule.recordServerError(statusCode: 503, errorCodes: [], retryAfter: 2, at: start)
        let first = try XCTUnwrap(schedule.cooldown)
        XCTAssertEqual(first, UpdateSchedule.Cooldown(until: start + 5 * minute, statusCode: 503, errorCodes: []))
        XCTAssertEqual(schedule.decision(at: start + 5 * minute - 1, minimumInterval: 0), .paused(first))
        XCTAssertEqual(schedule.decision(at: start + 5 * minute, minimumInterval: 0), .check)

        schedule.recordServerError(statusCode: 502, errorCodes: ["UPSTREAM_DOWN"], retryAfter: nil, at: start + 5 * minute)
        XCTAssertEqual(schedule.cooldown, UpdateSchedule.Cooldown(until: start + 15 * minute, statusCode: 502, errorCodes: ["UPSTREAM_DOWN"]), "The pause keeps the codes it reports")

        // Any answer but a 5xx ends the series
        schedule.recordAnswer()
        schedule.recordServerError(statusCode: 503, errorCodes: [], retryAfter: nil, at: start + hour)
        XCTAssertEqual(schedule.cooldown?.until, start + hour + 5 * minute)

        schedule.recordSuccess(at: start + 2 * hour)
        XCTAssertNil(schedule.cooldown)
        XCTAssertEqual(schedule.consecutiveServerErrors, 0)
        XCTAssertEqual(schedule.lastSuccessfulUpdate, start + 2 * hour)
    }

    func testUsageLimitPausesChecksAndEndsAServerErrorSeries() {
        var schedule = UpdateSchedule(scope: scope)
        schedule.recordServerError(statusCode: 503, errorCodes: [], retryAfter: nil, at: start)

        schedule.recordUsageLimit(errorCodes: ["USAGE_LIMIT_EXCEEDED"], retryAfter: 3 * hour, at: start)

        XCTAssertEqual(schedule.cooldown, UpdateSchedule.Cooldown(until: start + 3 * hour, statusCode: 429, errorCodes: ["USAGE_LIMIT_EXCEEDED"]))
        XCTAssertEqual(schedule.consecutiveServerErrors, 0)
    }

    func testPauseIsReportedWithTheFailureThatCausedIt() {
        let usageLimit = UpdateSchedule.Cooldown(until: start, statusCode: 429, errorCodes: ["USAGE_LIMIT_EXCEEDED"]).error
        guard case .apiError(429, let message?, ["USAGE_LIMIT_EXCEEDED"]) = usageLimit else {
            return XCTFail("\(usageLimit)")
        }
        XCTAssertTrue(message.hasPrefix("Usage limit reached. Update checks are paused until"), message)

        let serverError = UpdateSchedule.Cooldown(until: start, statusCode: 503, errorCodes: []).error
        guard case .apiError(503, let message?, []) = serverError else {
            return XCTFail("\(serverError)")
        }
        XCTAssertTrue(message.hasPrefix("The LingoHub CDN is unavailable (HTTP 503). Update checks are paused until"), message)
    }

    // MARK: - Persistence

    func testScheduleSurvivesARelaunchForTheSameScopeOnly() {
        var schedule = UpdateSchedule(scope: scope)
        schedule.recordServerError(statusCode: 503, errorCodes: [], retryAfter: nil, at: start)
        schedule.recordUsageLimit(errorCodes: ["USAGE_LIMIT_EXCEEDED"], retryAfter: nil, at: start)
        schedule.save()

        XCTAssertEqual(UpdateSchedule.load(scope: scope), schedule)

        // Another app version, environment or CDN key checks right away
        for other in [
            UpdateSchedule.Scope(appVersion: "1.0.1", environment: .production, apiKey: "lh-cdn_key"),
            UpdateSchedule.Scope(appVersion: "1.0.0", environment: .staging, apiKey: "lh-cdn_key"),
            UpdateSchedule.Scope(appVersion: "1.0.0", environment: .production, apiKey: "lh-cdn_other")
        ] {
            XCTAssertEqual(UpdateSchedule.load(scope: other), UpdateSchedule(scope: other), "\(other)")
        }

        UpdateSchedule.remove()
        XCTAssertEqual(UpdateSchedule.load(scope: scope), UpdateSchedule(scope: scope))
    }

    func testScopeStoresOnlyADigestOfTheCDNKey() throws {
        UpdateSchedule(scope: scope).save()

        let stored = try XCTUnwrap(UserDefaults.standard.data(forKey: LingoHubConstants.updateSchedule))
        XCTAssertFalse(String(decoding: stored, as: UTF8.self).contains("lh-cdn_key"))
        XCTAssertEqual(scope.apiKeyDigest.count, 64)
    }

    func testUnreadableScheduleStartsFresh() {
        UserDefaults.standard.set(Data("not json".utf8), forKey: LingoHubConstants.updateSchedule)

        XCTAssertEqual(UpdateSchedule.load(scope: scope), UpdateSchedule(scope: scope))
    }

    // MARK: - Retry-After

    func testRetryAfterDelaySeconds() {
        XCTAssertEqual(RetryAfter.delay(fromHeaderValue: "120"), 120)
        XCTAssertEqual(RetryAfter.delay(fromHeaderValue: " 3 "), 3)
        XCTAssertEqual(RetryAfter.delay(fromHeaderValue: "0"), 0)
        XCTAssertEqual(RetryAfter.delay(fromHeaderValue: "99999999999999999999"), 99_999_999_999_999_999_999)
    }

    func testRetryAfterHTTPDate() {
        let now = Date(timeIntervalSince1970: 1_792_481_280) // Tue, 20 Oct 2026 07:28:00 GMT
        XCTAssertEqual(RetryAfter.delay(fromHeaderValue: "Wed, 21 Oct 2026 07:28:00 GMT", now: now), 24 * hour)
        XCTAssertEqual(RetryAfter.delay(fromHeaderValue: "Mon, 19 Oct 2026 07:28:00 GMT", now: now), 0, "A date in the past means now")
    }

    func testMalformedRetryAfterIsIgnored() {
        for value in [nil, "", "   ", "-1", "1.5", "+3", "soon", "Wed, 21 Oct 2026"] {
            XCTAssertNil(RetryAfter.delay(fromHeaderValue: value), String(describing: value))
        }
    }
}

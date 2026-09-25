//
//  UpdatePolicy.swift
//

import Foundation

/// How often the SDK checks for updates and how it reacts to a failed check: the
/// "Failures and retries" policy in the README, shared with the Android SDK
/// (lingohub/organization#2351).
///
/// The CDN answers from a single-primary database, so a crowd of clients retrying
/// together can keep it down. The policy is conservative for that reason: at most one
/// retry per failure, then a pause that survives app restarts (see `UpdateSchedule`).
enum UpdatePolicy {
    /// The minimum time between successful update checks in release builds.
    static let releaseMinimumCheckInterval: TimeInterval = 15 * 60

    /// The default of `LingoHubSDK.minimumCheckInterval`: 15 minutes, and 0 in debug
    /// builds so that every `update()` call checks during development.
    static var defaultMinimumCheckInterval: TimeInterval {
        #if DEBUG
        return 0
        #else
        return releaseMinimumCheckInterval
        #endif
    }

    /// Delay before the single retry after a 5xx without `Retry-After`, drawn per retry.
    static let serverErrorRetryDelay: ClosedRange<TimeInterval> = 2...5

    /// The longest `Retry-After` the SDK waits for before its single retry. A longer
    /// one skips the retry and pauses checks right away.
    static let maximumRetryWait: TimeInterval = 10

    /// The pause after an update failed with a 5xx; it doubles with every further
    /// failure in a row, up to `maximumServerErrorCooldown`.
    static let initialServerErrorCooldown: TimeInterval = 5 * 60
    static let maximumServerErrorCooldown: TimeInterval = 60 * 60

    /// The pause after a 429 (the CDN usage budget is exhausted).
    static let usageLimitCooldown: TimeInterval = 60 * 60

    /// No pause lasts longer, whatever `Retry-After` asks for, so a bogus header can
    /// never stop updates for good.
    static let maximumCooldown: TimeInterval = 24 * 60 * 60

    /// The wait before the single retry after a 5xx: the `Retry-After` delay, or 2–5
    /// seconds without one, placed within that range by `randomFraction` (0...1). Nil when
    /// `Retry-After` asks for more than `maximumRetryWait`, which skips the retry.
    static func serverErrorRetryDelay(retryAfter: TimeInterval?, randomFraction: Double = .random(in: 0...1)) -> TimeInterval? {
        guard let retryAfter else {
            let span = serverErrorRetryDelay.upperBound - serverErrorRetryDelay.lowerBound
            return serverErrorRetryDelay.lowerBound + min(max(randomFraction, 0), 1) * span
        }
        return retryAfter <= maximumRetryWait ? retryAfter : nil
    }

    /// The pause after an update failed with a 5xx: 5 minutes after the first failure,
    /// doubling with each further one in a row up to an hour, and never shorter than
    /// `Retry-After`.
    ///
    /// - Parameter consecutiveFailures: failed updates in a row, this one included.
    static func serverErrorCooldown(consecutiveFailures: Int, retryAfter: TimeInterval?) -> TimeInterval {
        // 5 · 2^12 minutes is far beyond the cap; limiting the exponent keeps the
        // arithmetic finite for any counter value.
        let doublings = min(max(consecutiveFailures - 1, 0), 12)
        let backoff = min(initialServerErrorCooldown * TimeInterval(1 << doublings), maximumServerErrorCooldown)
        return min(max(backoff, retryAfter ?? 0), maximumCooldown)
    }

    /// The pause after a 429: an hour, or `Retry-After` when that is longer.
    static func usageLimitCooldown(retryAfter: TimeInterval?) -> TimeInterval {
        return min(max(usageLimitCooldown, retryAfter ?? 0), maximumCooldown)
    }
}

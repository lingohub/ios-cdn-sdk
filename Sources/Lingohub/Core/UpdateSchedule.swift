//
//  UpdateSchedule.swift
//

import CryptoKit
import Foundation

/// The persisted pacing state of update checks: when the last update succeeded, and
/// whether a failure paused checks (see `UpdatePolicy`).
///
/// Stored as one UserDefaults value, so it is always written as a whole. It is valid
/// only for the checks it was recorded for (see `Scope`): a new app version, another
/// environment or another CDN key checks right away.
struct UpdateSchedule: Codable, Equatable {
    /// The checks a schedule applies to. The CDN's answers for one app version,
    /// environment and CDN key say nothing about another, so a change of any of them
    /// starts a fresh schedule.
    struct Scope: Codable, Equatable {
        let appVersion: String
        let environment: Environment
        /// SHA-256 of the CDN key: enough to notice a change, and the key itself is
        /// never stored.
        let apiKeyDigest: String

        init(appVersion: String, environment: Environment, apiKey: String) {
            self.appVersion = appVersion
            self.environment = environment
            self.apiKeyDigest = SHA256.hash(data: Data(apiKey.utf8)).map { String(format: "%02x", $0) }.joined()
        }
    }

    /// Update checks are paused until `until` after the failure described by
    /// `statusCode` and `errorCodes`.
    struct Cooldown: Codable, Equatable {
        let until: Date
        let statusCode: Int
        let errorCodes: [String]
    }

    /// What an `update()` call does at a given time.
    enum Decision: Equatable {
        /// Contact the CDN.
        case check
        /// Skip: the last successful update is less than the minimum interval ago.
        case skip(until: Date)
        /// Fail without contacting the CDN: a failure paused checks.
        case paused(Cooldown)
    }

    let scope: Scope
    /// When the last update succeeded; the minimum interval counts from here.
    private(set) var lastSuccessfulUpdate: Date?
    /// Updates in a row that failed with a 5xx; the cooldown doubles with each.
    private(set) var consecutiveServerErrors = 0
    private(set) var cooldown: Cooldown?

    init(scope: Scope) {
        self.scope = scope
    }
}

extension UpdateSchedule {
    func decision(at now: Date, minimumInterval: TimeInterval) -> Decision {
        // A cooldown ending further out than any the SDK sets means the clock was turned
        // back; it must not hold updates for longer than intended.
        if let cooldown, now < cooldown.until, cooldown.until.timeIntervalSince(now) <= UpdatePolicy.maximumCooldown {
            return .paused(cooldown)
        }
        // Likewise, a last update "in the future" does not delay the next one.
        if let lastSuccessfulUpdate, now >= lastSuccessfulUpdate {
            let nextCheck = lastSuccessfulUpdate.addingTimeInterval(max(0, minimumInterval))
            if now < nextCheck {
                return .skip(until: nextCheck)
            }
        }
        return .check
    }

    /// The update succeeded: the CDN answered and any release it offered is installed.
    mutating func recordSuccess(at now: Date) {
        lastSuccessfulUpdate = now
        consecutiveServerErrors = 0
        cooldown = nil
    }

    /// The CDN answered with anything but a 5xx, which ends a series of server errors.
    mutating func recordAnswer() {
        consecutiveServerErrors = 0
    }

    /// An update failed with a 5xx: pause checks, backing off with every failure in a row.
    mutating func recordServerError(statusCode: Int, errorCodes: [String], retryAfter: TimeInterval?, at now: Date) {
        consecutiveServerErrors += 1
        let duration = UpdatePolicy.serverErrorCooldown(consecutiveFailures: consecutiveServerErrors, retryAfter: retryAfter)
        cooldown = Cooldown(until: now.addingTimeInterval(duration), statusCode: statusCode, errorCodes: errorCodes)
    }

    /// The CDN answered 429: pause checks for an hour, or for `Retry-After` when longer.
    mutating func recordUsageLimit(errorCodes: [String], retryAfter: TimeInterval?, at now: Date) {
        consecutiveServerErrors = 0
        let duration = UpdatePolicy.usageLimitCooldown(retryAfter: retryAfter)
        cooldown = Cooldown(until: now.addingTimeInterval(duration), statusCode: 429, errorCodes: errorCodes)
    }
}

extension UpdateSchedule.Cooldown {
    /// What `update()` reports while this cooldown lasts.
    var error: LingoHubSDKError {
        let message = statusCode == 429
            ? "Usage limit reached. Update checks are paused until \(until)."
            : "The LingoHub CDN is unavailable (HTTP \(statusCode)). Update checks are paused until \(until)."
        return .apiError(statusCode: statusCode, message: message, errorCodes: errorCodes)
    }
}

// MARK: Persistence

extension UpdateSchedule {
    /// The schedule stored for `scope`, or a fresh one when none is stored for it.
    static func load(scope: Scope, from defaults: UserDefaults = .standard) -> UpdateSchedule {
        guard let data = defaults.data(forKey: LingoHubConstants.updateSchedule),
              let schedule = try? JSONDecoder().decode(UpdateSchedule.self, from: data),
              schedule.scope == scope else {
            return UpdateSchedule(scope: scope)
        }
        return schedule
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: LingoHubConstants.updateSchedule)
    }

    static func remove(from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: LingoHubConstants.updateSchedule)
    }
}

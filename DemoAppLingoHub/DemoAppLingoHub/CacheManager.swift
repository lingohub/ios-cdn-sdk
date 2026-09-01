//
//  CacheManager.swift
//
//  Created by Manfred Baldauf on 01.04.25.
//

import Foundation

/// Throttles update checks so the app doesn't hit the CDN on every foreground
/// transition — the check pattern recommended in the SDK README.
class UpdateThrottle {
    private let userDefaults = UserDefaults.standard
    private let lastFetchKey = "last_fetch_time"
    private let oneDayInSeconds: TimeInterval = 24 * 60 * 60

    func shouldCheckForUpdates() -> Bool {
        let lastFetchTime = userDefaults.double(forKey: lastFetchKey)
        let currentTime = Date().timeIntervalSince1970
        return currentTime - lastFetchTime >= oneDayInSeconds
    }

    func markCheckedNow() {
        let currentTime = Date().timeIntervalSince1970
        userDefaults.set(currentTime, forKey: lastFetchKey)
    }
}

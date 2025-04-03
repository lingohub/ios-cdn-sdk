//
//  CacheManager.swift
//
//  Created by Manfred Baldauf on 01.04.25.
//

import Foundation

class CacheManager {
    private let userDefaults = UserDefaults.standard
    private let lastFetchKey = "last_fetch_time"
    private let oneDayInSeconds: TimeInterval = 24 * 60 * 60

    func shouldFetchStrings() -> Bool {
        let lastFetchTime = userDefaults.double(forKey: lastFetchKey)
        let currentTime = Date().timeIntervalSince1970
        return currentTime - lastFetchTime >= oneDayInSeconds
    }

    func updateLastFetchTime() {
        let currentTime = Date().timeIntervalSince1970
        userDefaults.set(currentTime, forKey: lastFetchKey)
    }
}

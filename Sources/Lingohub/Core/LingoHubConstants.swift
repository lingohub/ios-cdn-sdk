//
//  LingohubConstants.swift
//
//
//  Created by Manfred Baldauf on 12.03.25.
//

import Foundation

struct LingohubConstants {
    /// The version of this SDK, reported to the Lingohub CDN as part of the client agent.
    /// Keep in sync with the release tag.
    static let version = "1.1.0"
    static let folderName = "Lingohub"
    static let basePath = "https://cdn.lingohub.com/"
    static let distributionVersion = "LingohubDistributionVersion"
    static let appVersion = "LingohubAppVersion"
    static let languageOverride = "LingohubLanguageOverride"
    static let usageCooldownUntil = "LingohubUsageCooldownUntil"
    /// How long update checks stay paused after the CDN reports an exhausted usage budget (429).
    static let usageLimitCooldownInterval: TimeInterval = 60 * 60
    static let updateNotification = "LingohubLocalization"
}


//
//  LingoHubConstants.swift
//
//
//  Created by Manfred Baldauf on 12.03.25.
//

import Foundation

struct LingoHubConstants {
    /// The version of this SDK, reported to the LingoHub CDN as part of the client agent.
    /// Keep in sync with the release tag.
    static let version = "2.1.0"
    static let folderName = "Lingohub"
    /// Subfolder of `folderName` holding the merged bundles behind `Bundle.lingohub`.
    static let mergedBundlesFolderName = "merged"
    static let basePath = "https://cdn.lingohub.com/"
    static let distributionVersion = "LingohubDistributionVersion"
    static let appVersion = "LingohubAppVersion"
    /// The folder (inside `releasesFolderName`) of the active release.
    static let releaseDirectory = "LingohubReleaseDirectory"
    /// Subfolder of `folderName` releases are installed into, each under a fresh name.
    static let releasesFolderName = "releases"
    static let languageOverride = "LingohubLanguageOverride"
    static let usageCooldownUntil = "LingohubUsageCooldownUntil"
    /// How long update checks stay paused after the CDN reports an exhausted usage budget (429).
    static let usageLimitCooldownInterval: TimeInterval = 60 * 60
    static let updateNotification = "LingohubLocalization"
    /// Prefix of the temporary directories a release archive is extracted into before
    /// it is atomically activated. Leftovers (from a crash mid-install) are removed on configure.
    static let stagingDirectoryPrefix = "staging-"
}

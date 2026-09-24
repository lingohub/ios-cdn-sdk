//
//  MergedBundle.swift
//
//  The bundle behind `Bundle.lingohub`: the app's compiled string tables with the
//  active release's entries laid over them, assembled on disk.
//

import CryptoKit
import Foundation

/// Swift-native lookups (`String(localized:)`, `LocalizedStringResource`,
/// `AttributedString(localized:)`, SwiftUI `Text`) never reach the swizzled
/// `Bundle.localizedString(forKey:value:table:)`, and Foundation never falls back from
/// one bundle to another for a missing key. They are therefore served from a real
/// bundle that holds everything: every table of the app bundle, with the release's
/// entries laid over it (built by `MergedBundleBuilder`).
///
/// Immutable once opened. `@unchecked` only because whether `Bundle` is annotated
/// `Sendable` depends on the SDK version; `Bundle` is documented thread-safe.
struct MergedBundle: @unchecked Sendable {
    let url: URL
    let manifest: MergedBundleManifest
    /// All languages. Foundation selects the localization exactly as it does for the
    /// app bundle.
    let bundle: Bundle
    /// Every `<language>.lproj`, opened as a bundle of its own. Foundation resolves each
    /// lookup in such a view against that one language, whatever locale the caller
    /// passes, which is how a `setLanguage(_:)` override is served.
    let languageBundles: [String: Bundle]

    /// Opens the merged bundle at `url`; nil when it is not a complete merged bundle.
    init?(url: URL) {
        guard let manifest = MergedBundleManifest(bundleURL: url), let bundle = Bundle(url: url) else {
            return nil
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        var languageBundles: [String: Bundle] = [:]
        for name in names where name.hasSuffix(".lproj") {
            let language = String(name.dropLast(".lproj".count))
            languageBundles[language] = Bundle(url: url.appendingPathComponent(name, isDirectory: true))
        }
        self.url = url
        self.manifest = manifest
        self.bundle = bundle
        self.languageBundles = languageBundles
    }

    /// The bundle serving `language`: its single-language view, or the all-language
    /// bundle when no override is set or the merged bundle has no such language (the
    /// same fallback swizzled lookups take).
    func bundle(forLanguage language: String?) -> Bundle {
        guard let language, let languageBundle = languageBundles[language] else {
            return bundle
        }
        return languageBundle
    }
}

// MARK: - Store

extension MergedBundle {
    /// A merged bundle in `folder` built from exactly the inputs `manifest` describes.
    static func reusable(matching manifest: MergedBundleManifest, in folder: URL) -> MergedBundle? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasSuffix(".bundle") {
            // Built from `folder` (not the enumerated URL, which resolves symlinks such as
            // /var → /private/var), so every merged bundle URL shares the folder's form.
            let url = folder.appendingPathComponent(name, isDirectory: true)
            if MergedBundleManifest(bundleURL: url) == manifest {
                return MergedBundle(url: url)
            }
        }
        return nil
    }

    /// Deletes everything in `folder` except the merged bundles at `kept`: superseded
    /// merged bundles and leftovers of interrupted builds. Best effort; failures are
    /// logged.
    static func removeAll(in folder: URL, keeping kept: [URL]) {
        let keptNames = Set(kept.map(\.lastPathComponent))
        let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for entry in entries where !keptNames.contains(entry.lastPathComponent) {
            do {
                try FileManager.default.removeItem(at: entry)
                LingoHubLogger.shared.log("Merged bundle: removed \(entry.lastPathComponent)")
            } catch {
                LingoHubLogger.shared.log("Merged bundle: could not remove \(entry.lastPathComponent): \(error)")
            }
        }
    }
}

/// The inputs a merged bundle was built from, stored in its Info.plist. A merged bundle
/// persisted by an earlier launch is reused only while all of them are unchanged.
struct MergedBundleManifest: Equatable, Sendable {
    /// Bump whenever the layout or the merge rules change, so bundles written by an
    /// older SDK are rebuilt instead of reused.
    static let currentFormatVersion = 1

    let formatVersion: Int
    /// The release whose entries are laid over the app's tables.
    let distributionVersion: String
    /// The app's string tables at build time (`MergedBundleSource.fingerprint()`).
    let sourceFingerprint: String

    private enum Key {
        static let formatVersion = "LingoHubMergedBundleFormat"
        static let distributionVersion = "LingoHubDistributionVersion"
        static let sourceFingerprint = "LingoHubSourceFingerprint"
    }

    init(distributionVersion: String, sourceFingerprint: String, formatVersion: Int = MergedBundleManifest.currentFormatVersion) {
        self.formatVersion = formatVersion
        self.distributionVersion = distributionVersion
        self.sourceFingerprint = sourceFingerprint
    }

    /// Reads the manifest from the Info.plist of the merged bundle at `bundleURL`.
    init?(bundleURL: URL) {
        guard let data = try? Data(contentsOf: bundleURL.appendingPathComponent("Info.plist")),
              let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let formatVersion = info[Key.formatVersion] as? Int,
              let distributionVersion = info[Key.distributionVersion] as? String,
              let sourceFingerprint = info[Key.sourceFingerprint] as? String else {
            return nil
        }
        self.init(distributionVersion: distributionVersion, sourceFingerprint: sourceFingerprint, formatVersion: formatVersion)
    }

    /// The merged bundle's Info.plist: a regular bundle that carries the app's
    /// development region, so Foundation's own language fallback keeps working, plus
    /// this manifest.
    func infoPlist(identifier: String, developmentRegion: String) -> [String: Any] {
        return [
            "CFBundleDevelopmentRegion": developmentRegion,
            "CFBundleIdentifier": identifier,
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundlePackageType": "BNDL",
            Key.formatVersion: formatVersion,
            Key.distributionVersion: distributionVersion,
            Key.sourceFingerprint: sourceFingerprint,
        ]
    }
}

/// The app side of a merged bundle: the bundle whose compiled tables are the base.
struct MergedBundleSource: Sendable {
    let resourcesURL: URL?
    let developmentRegion: String
    /// `CFBundleShortVersionString (CFBundleVersion)`, part of the fingerprint.
    let version: String

    init(bundle: Bundle) {
        let info = bundle.infoDictionary ?? [:]
        resourcesURL = bundle.resourceURL
        developmentRegion = bundle.developmentLocalization ?? "en"
        version = "\(info["CFBundleShortVersionString"] as? String ?? "") (\(info["CFBundleVersion"] as? String ?? ""))"
    }

    /// Fingerprint of the app's compiled string tables: path, size, and modification
    /// date of every table file, plus the bundle version and development region. A new
    /// app build that ships different tables changes it, and computing it reads no table.
    func fingerprint() -> String {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        var hasher = SHA256()
        hasher.update(data: Data("\(version)|\(developmentRegion)".utf8))
        let files = StringTableIndex(directory: resourcesURL, includingRootTables: true, prefetching: Array(keys)).files
        for file in files.sorted(by: { $0.path < $1.path }) {
            let values = try? file.resourceValues(forKeys: keys)
            let modified = values?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
            let entry = "\n\(file.deletingLastPathComponent().lastPathComponent)/\(file.lastPathComponent)|\(values?.fileSize ?? -1)|\(modified)"
            hasher.update(data: Data(entry.utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

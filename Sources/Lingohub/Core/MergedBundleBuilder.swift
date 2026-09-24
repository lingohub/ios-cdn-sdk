//
//  MergedBundleBuilder.swift
//
//  Assembles the merged bundle for one release from the app bundle's compiled
//  string tables and the release's tables.
//

import Foundation

/// The compiled string tables of every `<language>.lproj` directly inside a directory:
/// the layout Foundation resolves, and the only one the CDN produces.
struct StringTableIndex {
    /// The files of one table: `<name>.strings` and/or `<name>.stringsdict`.
    struct Table {
        var strings: URL?
        var stringsdict: URL?
    }

    /// Language (the `.lproj` name without extension) → table name → files.
    private(set) var languages: [String: [String: Table]] = [:]

    /// - Parameter keys: resource values to prefetch for every table file.
    init(directory: URL?, prefetching keys: [URLResourceKey] = []) {
        let fileManager = FileManager.default
        guard let directory,
              let entries = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return
        }
        for lproj in entries where lproj.pathExtension == "lproj" && (try? lproj.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            let files = (try? fileManager.contentsOfDirectory(at: lproj, includingPropertiesForKeys: keys)) ?? []
            var tables: [String: Table] = [:]
            for file in files where !file.lh_isMacOSMetadata {
                let name = file.deletingPathExtension().lastPathComponent
                switch file.pathExtension {
                case "strings":
                    tables[name, default: Table()].strings = file
                case "stringsdict":
                    tables[name, default: Table()].stringsdict = file
                default:
                    continue
                }
            }
            if !tables.isEmpty {
                languages[lproj.deletingPathExtension().lastPathComponent] = tables
            }
        }
    }

    /// Every table file in the index.
    var files: [URL] {
        return languages.values.flatMap { tables in
            tables.values.flatMap { [$0.strings, $0.stringsdict].compactMap { $0 } }
        }
    }
}

/// Builds the merged bundle for one release: for every language and table of the app
/// bundle and the release, the app's compiled table with the release's entries laid
/// over it. Tables the release does not touch are copied unchanged (a copy-on-write
/// clone on APFS). A language only the release has gets the app's development-language
/// tables as its base, so keys the release lacks still read as bundled text.
///
/// The build happens in a staging directory and is published with a single rename,
/// under a fresh name: Foundation caches bundles and their tables by path, so a path is
/// never reused for different content.
struct MergedBundleBuilder: Sendable {
    enum BuildError: Error, LocalizedError {
        case releaseMissing
        case unreadableTable(String)
        case unreadableBundle

        var errorDescription: String? {
            switch self {
            case .releaseMissing:
                return "The release to merge is no longer installed."
            case .unreadableTable(let name):
                return "The string table \(name) could not be read."
            case .unreadableBundle:
                return "The merged bundle could not be opened."
            }
        }
    }

    let source: MergedBundleSource
    /// The installed release (`update.bundle`).
    let releaseURL: URL

    /// Builds the merged bundle into `folder` and returns it opened.
    func build(distributionVersion: String, in folder: URL) throws -> MergedBundle {
        let fileManager = FileManager.default
        // `folder` lives next to the release. When the release was discarded while this
        // build waited, stop instead of recreating the storage folder.
        guard releaseURL.lh_isDirectory else {
            throw BuildError.releaseMissing
        }

        let manifest = MergedBundleManifest(distributionVersion: distributionVersion, sourceFingerprint: source.fingerprint())
        let name = UUID().uuidString
        let stagingURL = folder.appendingPathComponent(LingoHubConstants.stagingDirectoryPrefix + name, isDirectory: true)
        let bundleURL = folder.appendingPathComponent(name + ".bundle", isDirectory: true)

        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        do {
            try writeTables(into: stagingURL)
            let info = manifest.infoPlist(identifier: "com.lingohub.sdk.merged.\(name)", developmentRegion: source.developmentRegion)
            try writePropertyList(info, to: stagingURL.appendingPathComponent("Info.plist"))
            try fileManager.moveItem(at: stagingURL, to: bundleURL)
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            throw error
        }

        guard let merged = MergedBundle(url: bundleURL) else {
            try? fileManager.removeItem(at: bundleURL)
            throw BuildError.unreadableBundle
        }
        LingoHubLogger.shared.log("Merged bundle: built \(bundleURL.lastPathComponent) for release \(distributionVersion) (\(merged.languageBundles.count) languages)")
        return merged
    }

    private func writeTables(into bundleURL: URL) throws {
        let app = StringTableIndex(directory: source.resourcesURL)
        let release = StringTableIndex(directory: releaseURL)
        let developmentTables = app.languages[source.developmentRegion] ?? app.languages["Base"] ?? [:]

        for language in Set(app.languages.keys).union(release.languages.keys) {
            let appTables = app.languages[language] ?? developmentTables
            let releaseTables = release.languages[language] ?? [:]
            let lprojURL = bundleURL.appendingPathComponent(language + ".lproj")
            try FileManager.default.createDirectory(at: lprojURL, withIntermediateDirectories: false)
            for table in Set(appTables.keys).union(releaseTables.keys) {
                try writeTable(named: table, app: appTables[table], release: releaseTables[table], into: lprojURL)
            }
        }
    }

    private func writeTable(named name: String, app: StringTableIndex.Table?, release: StringTableIndex.Table?, into lprojURL: URL) throws {
        let fileManager = FileManager.default
        let stringsURL = lprojURL.appendingPathComponent(name + ".strings")
        let stringsdictURL = lprojURL.appendingPathComponent(name + ".stringsdict")

        guard let release else {
            if let url = app?.strings {
                try fileManager.copyItem(at: url, to: stringsURL)
            }
            if let url = app?.stringsdict {
                try fileManager.copyItem(at: url, to: stringsdictURL)
            }
            return
        }

        let releaseStrings = try release.strings.map(readStrings) ?? [:]
        let releaseStringsdict = try release.stringsdict.map(readStringsdict) ?? [:]
        // The release is authoritative for every key it contains, across both files: a
        // key it ships as a plain string must lose the app's plural or device variants
        // (Foundation prefers the `.stringsdict` entry), and the other way round. This
        // is also what swizzled lookups serve.
        let releaseKeys = Set(releaseStrings.keys).union(releaseStringsdict.keys)
        let strings = (try app?.strings.map(readStrings) ?? [:])
            .filter { !releaseKeys.contains($0.key) }
            .merging(releaseStrings) { _, release in release }
        let stringsdict = (try app?.stringsdict.map(readStringsdict) ?? [:])
            .filter { !releaseKeys.contains($0.key) }
            .merging(releaseStringsdict) { _, release in release }

        if !strings.isEmpty {
            try writePropertyList(strings, to: stringsURL)
        }
        if !stringsdict.isEmpty {
            try writePropertyList(stringsdict, to: stringsdictURL)
        }
    }

    /// `[String: String]`: the contract the installer validates and the loaders apply.
    private func readStrings(_ url: URL) throws -> [String: String] {
        guard let table = NSDictionary(contentsOf: url) as? [String: String] else {
            throw BuildError.unreadableTable(url.lastPathComponent)
        }
        return table
    }

    private func readStringsdict(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let table = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw BuildError.unreadableTable(url.lastPathComponent)
        }
        return table
    }

    private func writePropertyList(_ propertyList: Any, to url: URL) throws {
        try PropertyListSerialization.data(fromPropertyList: propertyList, format: .binary, options: 0).write(to: url)
    }
}

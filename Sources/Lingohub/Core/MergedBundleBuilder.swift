//
//  MergedBundleBuilder.swift
//
//  Assembles the merged bundle for one release from the app bundle's compiled
//  string tables and the release's tables.
//

import Foundation

/// The compiled string tables of every `<language>.lproj` directly inside a directory
/// (the layout Foundation resolves, and the only one the CDN produces), plus, on
/// request, the nonlocalized tables directly in it (an app bundle can have those).
struct StringTableIndex {
    /// The files of one table: `<name>.strings` and/or `<name>.stringsdict`.
    struct Table {
        var strings: URL?
        var stringsdict: URL?
    }

    /// Language (the `.lproj` name without extension) → table name → files.
    private(set) var languages: [String: [String: Table]] = [:]
    /// Table name → files outside any `.lproj`; empty unless requested.
    private(set) var rootTables: [String: Table] = [:]

    /// - Parameters:
    ///   - includingRootTables: Also index nonlocalized tables directly in `directory`.
    ///   - keys: Resource values to prefetch for every table file.
    init(directory: URL?, includingRootTables: Bool = false, prefetching keys: [URLResourceKey] = []) {
        let fileManager = FileManager.default
        guard let directory,
              let entries = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey] + keys) else {
            return
        }
        var rootFiles: [URL] = []
        for entry in entries {
            if entry.pathExtension == "lproj", (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                let files = (try? fileManager.contentsOfDirectory(at: entry, includingPropertiesForKeys: keys)) ?? []
                let tables = Self.tables(in: files)
                if !tables.isEmpty {
                    languages[entry.deletingPathExtension().lastPathComponent] = tables
                }
            } else {
                rootFiles.append(entry)
            }
        }
        if includingRootTables {
            rootTables = Self.tables(in: rootFiles)
        }
    }

    private static func tables(in files: [URL]) -> [String: Table] {
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
        return tables
    }

    /// Every table file in the index.
    var files: [URL] {
        let tables = languages.values.flatMap(\.values) + rootTables.values
        return tables.flatMap { [$0.strings, $0.stringsdict].compactMap { $0 } }
    }
}

/// Builds the merged bundle for one release: every language folder holds, for each
/// table, the app table a Foundation lookup in that language resolves, with the
/// release's entries laid over it. Tables the release does not touch are copied
/// unchanged (a copy-on-write clone on APFS).
///
/// Foundation resolves a table file by file, in this order: a nonlocalized file at the
/// resources root, the language, its base language (`de` for `de-AT`), `Base`, and the
/// development language. The merged bundle resolves that per language up front, so a
/// table the release adds for a language cannot hide the app's fallback for the keys
/// the release lacks, and every language folder is self-contained, which the
/// single-language views that serve `setLanguage(_:)` rely on.
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
    /// The release the merged bundle is built for (`distributionReleaseId`).
    let distributionVersion: String
    /// The folder merged bundles are built in.
    let folder: URL

    /// Builds the merged bundle from the release files at `releaseURL` (a validated
    /// staging directory during an install, `update.bundle` at launch) and returns it
    /// opened.
    func build(from releaseURL: URL) throws -> MergedBundle {
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
            try writeTables(from: releaseURL, into: stagingURL)
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

    private func writeTables(from releaseURL: URL, into bundleURL: URL) throws {
        let app = StringTableIndex(directory: source.resourcesURL, includingRootTables: true)
        let release = StringTableIndex(directory: releaseURL)

        for language in Set(app.languages.keys).union(release.languages.keys) {
            let fallbacks = fallbackLanguages(of: language)
            let appTables = effectiveTables(for: [language] + fallbacks, in: app)
            let releaseTables = release.languages[language] ?? [:]
            var tables: [String: (app: StringTableIndex.Table?, release: StringTableIndex.Table?)] = [:]
            for name in Set(appTables.keys).union(releaseTables.keys) {
                tables[name] = (appTables[name], releaseTables[name])
            }
            // A table neither the app nor this language's release has, but a fallback
            // language's release does, resolves there for a lookup of the whole bundle
            for fallback in fallbacks {
                for (name, releaseTable) in release.languages[fallback] ?? [:] where tables[name] == nil {
                    tables[name] = (nil, releaseTable)
                }
            }

            let lprojURL = bundleURL.appendingPathComponent(language + ".lproj")
            try FileManager.default.createDirectory(at: lprojURL, withIntermediateDirectories: false)
            for (name, table) in tables {
                try writeTable(named: name, app: table.app, release: table.release, into: lprojURL)
            }
        }
    }

    /// The languages Foundation falls back to, in order, for a table file missing in
    /// `language`: its base language, `Base`, and the development language.
    private func fallbackLanguages(of language: String) -> [String] {
        var fallbacks: [String] = []
        if let baseLanguage = language.split(separator: "-").first.map(String.init), baseLanguage != language {
            fallbacks.append(baseLanguage)
        }
        for fallback in ["Base", source.developmentRegion] where fallback != language && !fallbacks.contains(fallback) {
            fallbacks.append(fallback)
        }
        return fallbacks
    }

    /// For every app table, the file a lookup through `searchOrder` resolves, file by
    /// file: a nonlocalized root file wins, then the first language that has it.
    private func effectiveTables(for searchOrder: [String], in app: StringTableIndex) -> [String: StringTableIndex.Table] {
        let localized = searchOrder.compactMap { app.languages[$0] }
        var tables: [String: StringTableIndex.Table] = [:]
        for name in Set(app.rootTables.keys).union(localized.flatMap(\.keys)) {
            let candidates = [app.rootTables[name]] + localized.map { $0[name] }
            tables[name] = StringTableIndex.Table(
                strings: candidates.lazy.compactMap { $0?.strings }.first,
                stringsdict: candidates.lazy.compactMap { $0?.stringsdict }.first
            )
        }
        return tables
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

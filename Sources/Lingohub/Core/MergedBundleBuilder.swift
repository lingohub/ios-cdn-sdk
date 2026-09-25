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
/// A plain Foundation lookup resolves the `.strings` and the `.stringsdict` of a table
/// each on its own, in this order: a nonlocalized file at the resources root, the
/// language, the localizations Foundation matches the language to (`de` for `de-AT`,
/// `zh-Hant` for `zh-Hant-TW`, `es-419` for `es-MX`), and `Base`. Only for a table the
/// language has no file of at all does it fall back to the development language. The
/// merged bundle resolves that per language up front, so every language folder is
/// self-contained, which the single-language views that serve `setLanguage(_:)` rely
/// on. The release's tables for the languages in that order are laid over each file, up
/// to the language the file comes from: a table the release adds for a language cannot
/// hide the app's fallback for the keys the release lacks, and an update of a language
/// reaches the languages that fall back to it, but never replaces a language's own
/// translation.
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
    /// staging directory during an install, the restored release at launch) and returns
    /// it opened.
    func build(from releaseURL: URL) throws -> MergedBundle {
        let fileManager = FileManager.default
        // `folder` shares the LingoHub folder with the releases. When the release was
        // discarded while this build waited, stop instead of recreating that folder.
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

        var languages = Set(app.languages.keys).union(release.languages.keys)
        if !app.rootTables.isEmpty {
            // Foundation serves nonlocalized tables in every language, but the merged
            // bundle serves them from language folders only: it needs a folder for every
            // language the app supports, whether or not the release has it
            languages.formUnion(source.localizations + [source.developmentRegion])
        }
        // Foundation breaks ties between equally good matches (fr-CA and fr-CH for fr-BE)
        // by position: the app's localizations keep the order the app matches in, the
        // others follow sorted, so every build resolves alike
        let appLocalizations = source.localizations + Set(app.languages.keys).subtracting(source.localizations).sorted()
        let allLocalizations = appLocalizations + languages.subtracting(appLocalizations).sorted()
        let developmentOrder = searchOrder(for: source.developmentRegion, appLocalizations: appLocalizations, allLocalizations: allLocalizations)

        for language in languages {
            let languageOrder = searchOrder(for: language, appLocalizations: appLocalizations, allLocalizations: allLocalizations)
            let fallbackOrder = languageOrder + developmentOrder.filter { !languageOrder.contains($0) }
            let lprojURL = bundleURL.appendingPathComponent(language + ".lproj")
            try FileManager.default.createDirectory(at: lprojURL, withIntermediateDirectories: false)

            var names = Set(app.rootTables.keys)
            for localization in fallbackOrder {
                names.formUnion(app.languages[localization, default: [:]].keys)
                names.formUnion(release.languages[localization, default: [:]].keys)
            }
            for name in names {
                // Foundation falls back to the development language only for a table the
                // language has no file of, never for a single file of it
                let languageHasTable = app.rootTables[name] != nil || languageOrder.contains { app.languages[$0]?[name] != nil }
                let order = languageHasTable ? languageOrder : fallbackOrder
                try writeTable(named: name, order: order, app: app, release: release, into: lprojURL)
            }
        }
    }

    /// The languages a lookup in `language` consults, in order, for each file of a table:
    /// the language itself, the localizations Foundation matches it to with the release's
    /// languages added and in the app on its own (a release that adds `de-AT` must not
    /// take the app's fallback to `de-CH` away), and `Base`.
    private func searchOrder(for language: String, appLocalizations: [String], allLocalizations: [String]) -> [String] {
        var order = [language]
        if language != "Base" {
            order += Self.localizations(matching: language, in: allLocalizations)
            order += Self.localizations(matching: language, in: appLocalizations)
        }
        order.append("Base")
        var seen = Set<String>()
        return order.filter { seen.insert($0).inserted }
    }

    /// The localizations Foundation resolves `language` to among `localizations`, best
    /// first: the language itself and its regional, script, and legacy equivalents
    /// (`zh-Hant` for `zh-Hant-TW`, `es-419` for `es-MX`, `iw` for `he`), never another
    /// language.
    private static func localizations(matching language: String, in localizations: [String]) -> [String] {
        let languageCode = Self.languageCode(of: language)
        // Foundation answers a language nothing matches with English or the first
        // candidate. Leading with Base, which matches no language, and keeping only the
        // language's own family drops those answers.
        let candidates = ["Base"] + localizations.filter { $0 != "Base" }
        return Bundle.preferredLocalizations(from: candidates, forPreferences: [language])
            .filter { $0 != "Base" && Self.languageCode(of: $0) == languageCode }
    }

    private static func languageCode(of localization: String) -> String? {
        let identifier = Locale.canonicalLanguageIdentifier(from: localization)
        return Locale.components(fromIdentifier: identifier)[NSLocale.Key.languageCode.rawValue]
    }

    /// One file of a table as a lookup resolves it: the app's file, and for how many
    /// languages of the lookup's order the release's tables update it.
    private struct ResolvedFile {
        var url: URL?
        var releaseDepth: Int
    }

    /// Writes table `name` into `lprojURL` as a lookup through `order` resolves it: each
    /// file on its own, from the nonlocalized one or the first language in `order` that
    /// has it, with the release's tables laid over it for the languages up to that one
    /// (all of them for a nonlocalized or missing file), so a release never replaces a
    /// more specific translation.
    private func writeTable(named name: String, order: [String], app: StringTableIndex, release: StringTableIndex, into lprojURL: URL) throws {
        let fileManager = FileManager.default
        let stringsURL = lprojURL.appendingPathComponent(name + ".strings")
        let stringsdictURL = lprojURL.appendingPathComponent(name + ".stringsdict")

        let localized = order.map { app.languages[$0]?[name] }
        func resolve(_ file: KeyPath<StringTableIndex.Table, URL?>) -> ResolvedFile {
            if let url = app.rootTables[name]?[keyPath: file] {
                return ResolvedFile(url: url, releaseDepth: order.count)
            }
            guard let index = localized.firstIndex(where: { $0?[keyPath: file] != nil }) else {
                return ResolvedFile(url: nil, releaseDepth: order.count)
            }
            return ResolvedFile(url: localized[index]?[keyPath: file], releaseDepth: index + 1)
        }
        let strings = resolve(\.strings)
        let stringsdict = resolve(\.stringsdict)
        let releaseTables = order.prefix(max(strings.releaseDepth, stringsdict.releaseDepth)).map { release.languages[$0]?[name] }

        guard releaseTables.contains(where: { $0 != nil }) else {
            if let url = strings.url {
                try fileManager.copyItem(at: url, to: stringsURL)
            }
            if let url = stringsdict.url {
                try fileManager.copyItem(at: url, to: stringsdictURL)
            }
            return
        }

        var stringsTable = try strings.url.map(readStrings) ?? [:]
        var stringsdictTable = try stringsdict.url.map(readStringsdict) ?? [:]
        // Least specific first, so the language's own release table is laid last. Each
        // is authoritative for every key it contains, across both files: a key it ships
        // as a plain string must lose the plural or device variants below it (Foundation
        // prefers the `.stringsdict` entry), and the other way round. This is also what
        // swizzled lookups serve.
        for (depth, releaseTable) in releaseTables.enumerated().reversed() {
            guard let releaseTable else { continue }
            let releaseStrings = try releaseTable.strings.map(readStrings) ?? [:]
            let releaseStringsdict = try releaseTable.stringsdict.map(readStringsdict) ?? [:]
            if depth < strings.releaseDepth {
                for key in releaseStringsdict.keys {
                    stringsTable[key] = nil
                }
                stringsTable.merge(releaseStrings) { _, release in release }
            }
            if depth < stringsdict.releaseDepth {
                for key in releaseStrings.keys {
                    stringsdictTable[key] = nil
                }
                stringsdictTable.merge(releaseStringsdict) { _, release in release }
            }
        }

        if !stringsTable.isEmpty {
            try writePropertyList(stringsTable, to: stringsURL)
        }
        if !stringsdictTable.isEmpty {
            try writePropertyList(stringsdictTable, to: stringsdictURL)
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

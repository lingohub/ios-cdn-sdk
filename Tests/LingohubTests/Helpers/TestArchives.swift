//
//  TestArchives.swift
//
//  Builds ZIP archives and release directories in code, so failure-path tests
//  don't need a checked-in fixture per case.
//

import CryptoKit
import Foundation
import XCTest
import ZIPFoundation

enum TestArchives {

    /// SHA-256 hex digest of a file, for checksum-verification tests.
    static func sha256Hex(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Creates a ZIP archive at `url` containing the given files (`path` → contents).
    static func zip(files: [String: Data], to url: URL) throws {
        let archive = try Archive(url: url, accessMode: .create)
        for (path, data) in files.sorted(by: { $0.key < $1.key }) {
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), provider: { position, size in
                let start = Int(position)
                return data.subdata(in: start..<(start + size))
            })
        }
    }

    /// Creates a release archive with one `Localizable.strings` per language
    /// (`language` → `key` → `value`).
    static func localizationZip(strings: [String: [String: String]], to url: URL) throws {
        var files: [String: Data] = [:]
        for (language, table) in strings {
            files["\(language).lproj/Localizable.strings"] = stringsFile(table)
        }
        try zip(files: files, to: url)
    }

    /// Creates a release directory (not zipped) with one `Localizable.strings` per
    /// language, for tests that activate a bundle directly.
    static func releaseDirectory(strings: [String: [String: String]], at url: URL) throws {
        let fileManager = FileManager.default
        for (language, table) in strings {
            let lproj = url.appendingPathComponent("\(language).lproj")
            try fileManager.createDirectory(at: lproj, withIntermediateDirectories: true)
            try stringsFile(table).write(to: lproj.appendingPathComponent("Localizable.strings"))
        }
    }

    /// A release laid out as the CDN ships it: `<language>.lproj/<table>.strings` as
    /// text and `<language>.lproj/<table>.stringsdict` as XML plists
    /// (`language` → `table` → `key` → value).
    static func releaseFiles(strings: [String: [String: [String: String]]], stringsdicts: [String: [String: [String: Any]]] = [:]) throws -> [String: Data] {
        var files: [String: Data] = [:]
        for (language, tables) in strings {
            for (table, entries) in tables {
                files["\(language).lproj/\(table).strings"] = stringsFile(entries)
            }
        }
        for (language, tables) in stringsdicts {
            for (table, entries) in tables {
                files["\(language).lproj/\(table).stringsdict"] = try PropertyListSerialization.data(fromPropertyList: entries, format: .xml, options: 0)
            }
        }
        return files
    }

    /// Writes `files` (`relative path` → contents) below `url`.
    static func write(files: [String: Data], to url: URL) throws {
        for (path, data) in files {
            let fileURL = url.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL)
        }
    }

    /// A bundle laid out like a built app: Info.plist plus `<language>.lproj` string
    /// tables compiled to binary plists, as Xcode ships them. Stands in for
    /// `Bundle.main` as the base of merged bundles.
    static func appBundle(
        at url: URL,
        developmentRegion: String = "en",
        strings: [String: [String: [String: String]]],
        stringsdicts: [String: [String: [String: Any]]] = [:]
    ) throws -> Bundle {
        var files: [String: Data] = [:]
        for (language, tables) in strings {
            for (table, entries) in tables {
                files["\(language).lproj/\(table).strings"] = try PropertyListSerialization.data(fromPropertyList: entries, format: .binary, options: 0)
            }
        }
        for (language, tables) in stringsdicts {
            for (table, entries) in tables {
                files["\(language).lproj/\(table).stringsdict"] = try PropertyListSerialization.data(fromPropertyList: entries, format: .binary, options: 0)
            }
        }
        let info: [String: Any] = [
            "CFBundleDevelopmentRegion": developmentRegion,
            "CFBundleIdentifier": "com.lingohub.tests.app",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0.0",
            "CFBundleVersion": "1",
        ]
        files["Info.plist"] = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try write(files: files, to: url)
        return try XCTUnwrap(Bundle(url: url))
    }

    /// A `.stringsdict` plural entry with `one` and `other` forms.
    static func plural(one: String, other: String, valueType: String = "lld") -> [String: Any] {
        return [
            "NSStringLocalizedFormatKey": "%#@count@",
            "count": [
                "NSStringFormatSpecTypeKey": "NSStringPluralRuleType",
                "NSStringFormatValueTypeKey": valueType,
                "one": one,
                "other": other,
            ] as [String: Any],
        ]
    }

    private static func stringsFile(_ table: [String: String]) -> Data {
        let content = table.map { "\"\($0.key)\" = \"\($0.value)\";" }.joined(separator: "\n")
        return Data(content.utf8)
    }
}

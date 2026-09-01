//
//  TestArchives.swift
//
//  Builds ZIP archives and release directories in code, so failure-path tests
//  don't need a checked-in fixture per case.
//

import CryptoKit
import Foundation
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

    private static func stringsFile(_ table: [String: String]) -> Data {
        let content = table.map { "\"\($0.key)\" = \"\($0.value)\";" }.joined(separator: "\n")
        return Data(content.utf8)
    }
}

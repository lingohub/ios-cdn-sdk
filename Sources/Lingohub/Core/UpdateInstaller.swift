//
//  UpdateInstaller.swift
//
//  Installs a downloaded release archive using a stage → validate → swap sequence.
//

import Foundation
import CryptoKit
import ZIPFoundation

/// Installs a downloaded translation archive without ever leaving the live bundle
/// in a partial state.
///
/// Invariant: at every point in time — including mid-install, after a thrown error,
/// or after a process crash — the live `update.bundle` directory is either the
/// complete previous release or the complete new release, never a mix. This holds
/// because extraction happens in a staging directory next to the live bundle and
/// the final activation is a single atomic filesystem replace.
///
/// An actor so archive verification, extraction, and validation run off the main
/// thread and concurrent installs are serialized.
actor UpdateInstaller {

    /// Resource limits applied to a release archive before extraction. Translation
    /// bundles are small; anything beyond these limits indicates a broken release
    /// (or a compression bomb) and is rejected to protect the host app.
    struct Limits: Sendable {
        var maxCompressedSize: Int64 = 50 * 1024 * 1024        // 50 MB archive
        var maxUncompressedSize: Int64 = 200 * 1024 * 1024     // 200 MB extracted
        var maxEntryCount = 10_000
    }

    enum InstallError: Error, LocalizedError {
        case unreadableArchive
        case archiveTooLarge(Int64)
        case tooManyEntries(Int)
        case uncompressedSizeTooLarge(Int64)
        case unsafeEntryPath(String)
        case checksumMismatch
        case noLocalizationContent
        case malformedLocalizationFile(String)

        var errorDescription: String? {
            switch self {
            case .unreadableArchive:
                return "The downloaded file is not a readable ZIP archive."
            case .archiveTooLarge(let size):
                return "The downloaded archive is too large (\(size) bytes)."
            case .tooManyEntries(let count):
                return "The downloaded archive contains too many entries (\(count))."
            case .uncompressedSizeTooLarge(let size):
                return "The archive's uncompressed size is too large (\(size) bytes)."
            case .unsafeEntryPath(let path):
                return "The archive contains an unsafe entry path: \(path)"
            case .checksumMismatch:
                return "The downloaded archive failed checksum verification."
            case .noLocalizationContent:
                return "The archive contains no localization content (.lproj with .strings/.stringsdict)."
            case .malformedLocalizationFile(let path):
                return "The archive contains a malformed localization file: \(path)"
            }
        }
    }

    /// Immutable and Sendable, so it is readable synchronously from outside the actor
    /// (the facade passes `maxCompressedSize` to the download layer as a streaming cap).
    let limits: Limits

    init(limits: Limits = Limits()) {
        self.limits = limits
    }

    /// Stages, validates, and atomically activates the archive at `archiveURL`.
    ///
    /// - Parameters:
    ///   - archiveURL: The downloaded ZIP archive.
    ///   - liveBundleURL: The destination the live bundle lives at (`…/Lingohub/update.bundle`).
    ///     Its parent directory is also used for the staging directory so the final
    ///     swap is a same-volume atomic replace.
    ///   - expectedSha256: Optional SHA-256 hex digest from the release metadata.
    ///     When present, the archive must match it before anything is extracted.
    /// - Returns: `liveBundleURL`, now containing the complete new release.
    func install(archiveURL: URL, liveBundleURL: URL, expectedSha256: String?) throws -> URL {
        let fileManager = FileManager.default
        let folderURL = liveBundleURL.deletingLastPathComponent()

        try preflight(archiveURL: archiveURL, expectedSha256: expectedSha256)

        // Stage next to the live bundle: the concluding rename is only guaranteed
        // atomic within a single volume.
        let stagingURL = folderURL.appendingPathComponent(LingoHubConstants.stagingDirectoryPrefix + UUID().uuidString)
        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)

        do {
            LingoHubLogger.shared.log("Installer: extracting archive to staging at \(stagingURL.lastPathComponent)")
            try fileManager.unzipItem(at: archiveURL, to: stagingURL)
            try hoistWrapperDirectoryIfNeeded(at: stagingURL)
            try validateStagedBundle(at: stagingURL)

            // Downloaded translations are re-downloadable; the exclusion travels
            // with the directory through the rename below.
            var stagingResourceURL = stagingURL
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? stagingResourceURL.setResourceValues(values)

            try activate(stagingURL: stagingURL, liveBundleURL: liveBundleURL)
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            throw error
        }

        LingoHubLogger.shared.log("Installer: release activated at \(liveBundleURL.path)")
        return liveBundleURL
    }

    // MARK: - Preflight

    private func preflight(archiveURL: URL, expectedSha256: String?) throws {
        let fileManager = FileManager.default

        let attributes = try? fileManager.attributesOfItem(atPath: archiveURL.path)
        let compressedSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        guard compressedSize <= limits.maxCompressedSize else {
            throw InstallError.archiveTooLarge(compressedSize)
        }

        if let expectedSha256 {
            let actual = try sha256Hex(of: archiveURL)
            guard actual.caseInsensitiveCompare(expectedSha256) == .orderedSame else {
                LingoHubLogger.shared.log("Installer: checksum mismatch, expected \(expectedSha256), got \(actual)")
                throw InstallError.checksumMismatch
            }
        }

        let archive: Archive
        do {
            archive = try Archive(url: archiveURL, accessMode: .read)
        } catch {
            throw InstallError.unreadableArchive
        }

        var entryCount = 0
        var uncompressedTotal: Int64 = 0
        for entry in archive {
            entryCount += 1
            guard entryCount <= limits.maxEntryCount else {
                throw InstallError.tooManyEntries(entryCount)
            }

            // ZIPFoundation sanitizes paths at extraction time as well; rejecting
            // early keeps the policy explicit and independent of the dependency.
            let path = entry.path
            if path.hasPrefix("/") || path.split(separator: "/").contains("..") || entry.type == .symlink {
                throw InstallError.unsafeEntryPath(path)
            }

            uncompressedTotal += Int64(clamping: entry.uncompressedSize)
            guard uncompressedTotal <= limits.maxUncompressedSize else {
                throw InstallError.uncompressedSizeTooLarge(uncompressedTotal)
            }
        }
    }

    private func sha256Hex(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Validation

    /// Archive junk that must not influence layout decisions or validation
    /// (macOS resource forks, AppleDouble files, Finder metadata).
    private func isJunk(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name == "__MACOSX" || name == ".DS_Store" || name.hasPrefix("._")
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return isDirectory.boolValue
    }

    /// Normalizes the common "zipped a folder" archive shape: when the staging root
    /// contains no `.lproj` directories but exactly one real directory that does, that
    /// wrapper's contents are hoisted to the root. Runtime lookup resolves `.lproj`
    /// folders only at the bundle root, so a wrapper left in place would produce a
    /// "successfully" installed release that serves nothing.
    private func hoistWrapperDirectoryIfNeeded(at stagingURL: URL) throws {
        let fileManager = FileManager.default
        let entries = (try? fileManager.contentsOfDirectory(at: stagingURL, includingPropertiesForKeys: nil))?
            .filter { !isJunk($0) } ?? []

        guard !entries.contains(where: { $0.lastPathComponent.hasSuffix(".lproj") }),
              entries.count == 1,
              let wrapper = entries.first,
              isDirectory(wrapper) else {
            return
        }

        let children = try fileManager.contentsOfDirectory(at: wrapper, includingPropertiesForKeys: nil)
        guard children.contains(where: { $0.lastPathComponent.hasSuffix(".lproj") }) else {
            return
        }

        LingoHubLogger.shared.log("Installer: hoisting wrapper directory '\(wrapper.lastPathComponent)'")
        for child in children {
            try fileManager.moveItem(at: child, to: stagingURL.appendingPathComponent(child.lastPathComponent))
        }
        try? fileManager.removeItem(at: wrapper)
    }

    /// A release is usable when the staging root contains at least one `<lang>.lproj`
    /// directory holding at least one valid `.strings`/`.stringsdict` file — the exact
    /// layout runtime lookup resolves (`Bundle.path(forResource:ofType:)` finds `.lproj`
    /// folders only at the bundle root). Validation applies the same contracts the
    /// loaders apply later: `.strings` must cast to `[String: String]` (the cast
    /// `loadStringsTable` performs), `.stringsdict` must be a dictionary plist.
    /// Any violation means the CDN produced a broken release; rejecting it keeps the
    /// previous, working translations active.
    private func validateStagedBundle(at stagingURL: URL) throws {
        let fileManager = FileManager.default
        let rootEntries = (try? fileManager.contentsOfDirectory(at: stagingURL, includingPropertiesForKeys: nil)) ?? []

        var localizationFileCount = 0
        for lprojURL in rootEntries where lprojURL.lastPathComponent.hasSuffix(".lproj") && isDirectory(lprojURL) {
            let files = (try? fileManager.contentsOfDirectory(at: lprojURL, includingPropertiesForKeys: nil)) ?? []
            for fileURL in files where !isJunk(fileURL) {
                let name = fileURL.lastPathComponent
                switch fileURL.pathExtension {
                case "strings":
                    guard NSDictionary(contentsOf: fileURL) as? [String: String] != nil else {
                        throw InstallError.malformedLocalizationFile(name)
                    }
                    localizationFileCount += 1
                case "stringsdict":
                    let data = try? Data(contentsOf: fileURL)
                    let plist = data.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) }
                    guard plist is [String: Any] else {
                        throw InstallError.malformedLocalizationFile(name)
                    }
                    localizationFileCount += 1
                default:
                    continue
                }
            }
        }

        guard localizationFileCount > 0 else {
            throw InstallError.noLocalizationContent
        }
    }

    // MARK: - Activation

    private func activate(stagingURL: URL, liveBundleURL: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: liveBundleURL.path) {
            _ = try fileManager.replaceItemAt(liveBundleURL, withItemAt: stagingURL)
        } else {
            try fileManager.moveItem(at: stagingURL, to: liveBundleURL)
        }
    }
}

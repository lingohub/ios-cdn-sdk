//
//  UpdateInstallerTests.swift
//
//  Unit tests for the stage → validate → swap install pipeline. The core property
//  under test: no failure mode ever leaves a partial or missing live bundle.
//

import XCTest
@testable import Lingohub

final class UpdateInstallerTests: XCTestCase {

    private var workDir: URL!
    private var liveBundleURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        workDir = FileManager.default.temporaryDirectory.appendingPathComponent("InstallerTests-\(UUID().uuidString)")
        let folder = workDir.appendingPathComponent("Lingohub")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        liveBundleURL = folder.appendingPathComponent("update.bundle")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: workDir)
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makeArchive(named name: String = UUID().uuidString, files: [String: Data]) throws -> URL {
        let url = workDir.appendingPathComponent("\(name).zip")
        try TestArchives.zip(files: files, to: url)
        return url
    }

    private func makeLocalizationArchive(value: String) throws -> URL {
        let url = workDir.appendingPathComponent("\(UUID().uuidString).zip")
        try TestArchives.localizationZip(strings: ["en": ["K": value]], to: url)
        return url
    }

    private func liveValue(forKey key: String = "K") -> String? {
        let stringsURL = liveBundleURL.appendingPathComponent("en.lproj/Localizable.strings")
        return (NSDictionary(contentsOf: stringsURL) as? [String: String])?[key]
    }

    private func stagingLeftoverExists() throws -> Bool {
        let folder = liveBundleURL.deletingLastPathComponent()
        let entries = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        return entries.contains { $0.hasPrefix(LingoHubConstants.stagingDirectoryPrefix) }
    }

    @discardableResult
    private func expectInstallError(
        _ installer: UpdateInstaller,
        archiveURL: URL,
        expectedSha256: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> UpdateInstaller.InstallError? {
        do {
            _ = try await installer.install(archiveURL: archiveURL, liveBundleURL: liveBundleURL, expectedSha256: expectedSha256)
            XCTFail("Expected the install to fail", file: file, line: line)
            return nil
        } catch let error as UpdateInstaller.InstallError {
            return error
        } catch {
            XCTFail("Expected InstallError, got \(error)", file: file, line: line)
            return nil
        }
    }

    // MARK: - Success paths

    func testInstallActivatesRelease() async throws {
        let installer = UpdateInstaller()
        let archive = try makeLocalizationArchive(value: "first")

        let installed = try await installer.install(archiveURL: archive, liveBundleURL: liveBundleURL, expectedSha256: nil)

        XCTAssertEqual(installed, liveBundleURL)
        XCTAssertEqual(liveValue(), "first")
        XCTAssertFalse(try stagingLeftoverExists())
    }

    func testInstallReplacesExistingRelease() async throws {
        let installer = UpdateInstaller()
        _ = try await installer.install(archiveURL: makeLocalizationArchive(value: "first"), liveBundleURL: liveBundleURL, expectedSha256: nil)

        _ = try await installer.install(archiveURL: makeLocalizationArchive(value: "second"), liveBundleURL: liveBundleURL, expectedSha256: nil)

        XCTAssertEqual(liveValue(), "second")
        XCTAssertFalse(try stagingLeftoverExists())
    }

    func testWrapperDirectoryArchiveIsHoistedAndUsable() async throws {
        // "Zipped a folder" archives put everything under one wrapper directory.
        // Runtime lookup resolves .lproj only at the bundle root, so the wrapper
        // must be hoisted - otherwise a "successful" install would serve nothing.
        let installer = UpdateInstaller()
        let archive = try makeArchive(files: [
            "MyBundle/en.lproj/Localizable.strings": Data("\"K\" = \"wrapped\";".utf8),
            "__MACOSX/._MyBundle": Data([0x00, 0x05])
        ])

        _ = try await installer.install(archiveURL: archive, liveBundleURL: liveBundleURL, expectedSha256: nil)

        XCTAssertEqual(liveValue(), "wrapped")
        // The layout the runtime actually resolves: .lproj as a direct child
        let bundle = try XCTUnwrap(Bundle(url: liveBundleURL))
        XCTAssertNotNil(bundle.path(forResource: "en", ofType: "lproj"))
    }

    func testDoublyNestedLocalizationRejected() async throws {
        // More than one level of nesting is not a shape runtime lookup can open,
        // and not one the hoist should guess about - reject it, keep the old release.
        let installer = UpdateInstaller()
        _ = try await installer.install(archiveURL: makeLocalizationArchive(value: "good"), liveBundleURL: liveBundleURL, expectedSha256: nil)

        let nested = try makeArchive(files: [
            "outer/inner/en.lproj/Localizable.strings": Data("\"K\" = \"lost\";".utf8)
        ])

        let error = await expectInstallError(installer, archiveURL: nested)
        guard case .noLocalizationContent = error else {
            return XCTFail("Expected noLocalizationContent, got \(String(describing: error))")
        }
        XCTAssertEqual(liveValue(), "good")
    }

    func testStringsFileWithNonStringValuesRejected() async throws {
        // NSDictionary(contentsOf:) also parses plists whose values are numbers or
        // arrays, but the runtime loader requires [String: String] and would serve an
        // empty table. Validation must apply the loader's contract.
        let installer = UpdateInstaller()
        _ = try await installer.install(archiveURL: makeLocalizationArchive(value: "good"), liveBundleURL: liveBundleURL, expectedSha256: nil)

        let xmlPlistWithInteger = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>K</key>
            <integer>5</integer>
        </dict>
        </plist>
        """
        let archive = try makeArchive(files: [
            "en.lproj/Localizable.strings": Data(xmlPlistWithInteger.utf8)
        ])

        let error = await expectInstallError(installer, archiveURL: archive)
        guard case .malformedLocalizationFile = error else {
            return XCTFail("Expected malformedLocalizationFile, got \(String(describing: error))")
        }
        XCTAssertEqual(liveValue(), "good")
    }

    func testArchiveJunkEntriesAreTolerated() async throws {
        // Real-world archives contain __MACOSX resource forks and AppleDouble files;
        // they must be ignored, not parsed as localization content.
        let installer = UpdateInstaller()
        let archive = try makeArchive(files: [
            "en.lproj/Localizable.strings": Data("\"K\" = \"value\";".utf8),
            "__MACOSX/en.lproj/._Localizable.strings": Data([0x00, 0x05, 0x16, 0x07]),
            "en.lproj/._junk.strings": Data([0x00, 0x05])
        ])

        _ = try await installer.install(archiveURL: archive, liveBundleURL: liveBundleURL, expectedSha256: nil)

        XCTAssertEqual(liveValue(), "value")
    }

    // MARK: - Failure paths preserve the previous release

    func testCorruptArchiveKeepsPreviousRelease() async throws {
        let installer = UpdateInstaller()
        _ = try await installer.install(archiveURL: makeLocalizationArchive(value: "good"), liveBundleURL: liveBundleURL, expectedSha256: nil)

        let corruptURL = workDir.appendingPathComponent("corrupt.zip")
        try Data("this is not a zip file".utf8).write(to: corruptURL)

        let error = await expectInstallError(installer, archiveURL: corruptURL)
        guard case .unreadableArchive = error else {
            return XCTFail("Expected unreadableArchive, got \(String(describing: error))")
        }

        XCTAssertEqual(liveValue(), "good", "A failed install must not touch the live release")
        XCTAssertFalse(try stagingLeftoverExists())
    }

    func testMalformedStringsFileKeepsPreviousRelease() async throws {
        let installer = UpdateInstaller()
        _ = try await installer.install(archiveURL: makeLocalizationArchive(value: "good"), liveBundleURL: liveBundleURL, expectedSha256: nil)

        let malformed = try makeArchive(files: [
            "en.lproj/Localizable.strings": Data("{{{{ not a strings file".utf8)
        ])

        let error = await expectInstallError(installer, archiveURL: malformed)
        guard case .malformedLocalizationFile = error else {
            return XCTFail("Expected malformedLocalizationFile, got \(String(describing: error))")
        }

        XCTAssertEqual(liveValue(), "good")
        XCTAssertFalse(try stagingLeftoverExists())
    }

    func testArchiveWithoutLocalizationContentRejected() async throws {
        let installer = UpdateInstaller()
        let archive = try makeArchive(files: ["readme.txt": Data("hello".utf8)])

        let error = await expectInstallError(installer, archiveURL: archive)
        guard case .noLocalizationContent = error else {
            return XCTFail("Expected noLocalizationContent, got \(String(describing: error))")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: liveBundleURL.path))
    }

    func testEmptyArchiveRejected() async throws {
        let installer = UpdateInstaller()
        let archive = try makeArchive(files: [:])

        let error = await expectInstallError(installer, archiveURL: archive)
        guard case .noLocalizationContent = error else {
            return XCTFail("Expected noLocalizationContent, got \(String(describing: error))")
        }
    }

    // MARK: - Resource limits

    func testOversizedArchiveRejected() async throws {
        let installer = UpdateInstaller(limits: .init(maxCompressedSize: 16))
        let archive = try makeLocalizationArchive(value: "value")

        let error = await expectInstallError(installer, archiveURL: archive)
        guard case .archiveTooLarge = error else {
            return XCTFail("Expected archiveTooLarge, got \(String(describing: error))")
        }
    }

    func testTooManyEntriesRejected() async throws {
        let installer = UpdateInstaller(limits: .init(maxEntryCount: 1))
        let archive = try makeArchive(files: [
            "en.lproj/Localizable.strings": Data("\"K\" = \"v\";".utf8),
            "de.lproj/Localizable.strings": Data("\"K\" = \"v\";".utf8)
        ])

        let error = await expectInstallError(installer, archiveURL: archive)
        guard case .tooManyEntries = error else {
            return XCTFail("Expected tooManyEntries, got \(String(describing: error))")
        }
    }

    func testExcessiveUncompressedSizeRejected() async throws {
        let installer = UpdateInstaller(limits: .init(maxUncompressedSize: 8))
        let archive = try makeArchive(files: [
            "en.lproj/Localizable.strings": Data(String(repeating: "\"K\" = \"v\";", count: 10).utf8)
        ])

        let error = await expectInstallError(installer, archiveURL: archive)
        guard case .uncompressedSizeTooLarge = error else {
            return XCTFail("Expected uncompressedSizeTooLarge, got \(String(describing: error))")
        }
    }

    // MARK: - Checksum

    func testChecksumMatchInstalls() async throws {
        let installer = UpdateInstaller()
        let archive = try makeLocalizationArchive(value: "verified")
        let sha256 = try TestArchives.sha256Hex(of: archive)

        _ = try await installer.install(archiveURL: archive, liveBundleURL: liveBundleURL, expectedSha256: sha256.uppercased())

        XCTAssertEqual(liveValue(), "verified")
    }

    func testChecksumMismatchKeepsPreviousRelease() async throws {
        let installer = UpdateInstaller()
        _ = try await installer.install(archiveURL: makeLocalizationArchive(value: "good"), liveBundleURL: liveBundleURL, expectedSha256: nil)

        let archive = try makeLocalizationArchive(value: "tampered")
        let error = await expectInstallError(installer, archiveURL: archive, expectedSha256: String(repeating: "0", count: 64))
        guard case .checksumMismatch = error else {
            return XCTFail("Expected checksumMismatch, got \(String(describing: error))")
        }

        XCTAssertEqual(liveValue(), "good")
    }
}

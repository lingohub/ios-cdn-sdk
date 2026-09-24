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

        XCTAssertEqual(installed.liveBundleURL, liveBundleURL)
        XCTAssertNil(installed.mergedBundle, "No merged bundle unless one is requested")
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

    func testWrapperDirectoryArchiveRejected() async throws {
        // The CDN produces .lproj directories at the archive root - the only layout
        // runtime lookup can resolve. A wrapper directory means the release was not
        // produced by the CDN pipeline; it is rejected, keeping the previous release.
        let installer = UpdateInstaller()
        _ = try await installer.install(archiveURL: makeLocalizationArchive(value: "good"), liveBundleURL: liveBundleURL, expectedSha256: nil)

        let wrapped = try makeArchive(files: [
            "MyBundle/en.lproj/Localizable.strings": Data("\"K\" = \"wrapped\";".utf8),
            "__MACOSX/._MyBundle": Data([0x00, 0x05])
        ])

        let error = await expectInstallError(installer, archiveURL: wrapped)
        guard case .noLocalizationContent = error else {
            return XCTFail("Expected noLocalizationContent, got \(String(describing: error))")
        }
        XCTAssertEqual(liveValue(), "good")
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

    // MARK: - Merged bundle

    private var mergedFolderURL: URL {
        return liveBundleURL.deletingLastPathComponent().appendingPathComponent("merged")
    }

    private func mergedBundleBuilder(appStrings: [String: String]) throws -> MergedBundleBuilder {
        let app = try TestArchives.appBundle(at: workDir.appendingPathComponent("App-\(UUID().uuidString).app"), strings: ["en": ["Localizable": appStrings]])
        return MergedBundleBuilder(source: MergedBundleSource(bundle: app), distributionVersion: "release-2", folder: mergedFolderURL)
    }

    func testInstallBuildsTheMergedBundleFromTheRelease() async throws {
        // Built from the validated staging directory before the swap, so the caller can
        // activate the release and its merged bundle at once.
        let installer = UpdateInstaller()
        _ = try await installer.install(archiveURL: makeLocalizationArchive(value: "first"), liveBundleURL: liveBundleURL, expectedSha256: nil)
        let builder = try mergedBundleBuilder(appStrings: ["K": "app value", "only_app": "only in the app"])

        let installed = try await installer.install(archiveURL: makeLocalizationArchive(value: "second"), liveBundleURL: liveBundleURL, expectedSha256: nil, mergedBundle: builder)

        let merged = try XCTUnwrap(installed.mergedBundle)
        let english = merged.bundle(forLanguage: "en")
        XCTAssertEqual(english.localizedString(forKey: "K", value: nil, table: nil), "second")
        XCTAssertEqual(english.localizedString(forKey: "only_app", value: nil, table: nil), "only in the app")
        XCTAssertEqual(merged.manifest.distributionVersion, "release-2")
        XCTAssertEqual(liveValue(), "second")
        XCTAssertFalse(try stagingLeftoverExists())
    }

    func testInstallSucceedsWhenTheMergedBundleCannotBeBuilt() async throws {
        let installer = UpdateInstaller()
        let builder = try mergedBundleBuilder(appStrings: ["K": "app value"])
        let appTable = try XCTUnwrap(builder.source.resourcesURL).appendingPathComponent("en.lproj/Localizable.strings")
        try Data("{{{{ not a strings file".utf8).write(to: appTable)

        let installed = try await installer.install(archiveURL: makeLocalizationArchive(value: "first"), liveBundleURL: liveBundleURL, expectedSha256: nil, mergedBundle: builder)

        XCTAssertNil(installed.mergedBundle)
        XCTAssertEqual(liveValue(), "first", "The release installs without its merged bundle")
    }

    func testRejectedArchiveBuildsNoMergedBundle() async throws {
        let installer = UpdateInstaller()
        _ = try await installer.install(archiveURL: makeLocalizationArchive(value: "good"), liveBundleURL: liveBundleURL, expectedSha256: nil)
        let builder = try mergedBundleBuilder(appStrings: ["K": "app value"])
        let malformed = try makeArchive(files: ["en.lproj/Localizable.strings": Data("{{{{ not a strings file".utf8)])

        do {
            _ = try await installer.install(archiveURL: malformed, liveBundleURL: liveBundleURL, expectedSha256: nil, mergedBundle: builder)
            XCTFail("Expected the install to fail")
        } catch is UpdateInstaller.InstallError {}

        XCTAssertEqual(liveValue(), "good")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: mergedFolderURL.path)) ?? []
        XCTAssertEqual(leftovers, [], "A rejected release must not leave a merged bundle behind")
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

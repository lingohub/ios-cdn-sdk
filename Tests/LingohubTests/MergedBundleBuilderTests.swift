//
//  MergedBundleBuilderTests.swift
//
//  Unit tests for the merged bundle behind `Bundle.lingohub`: the merge rules, the
//  layout Foundation reads, and store housekeeping.
//

import XCTest
@testable import Lingohub

final class MergedBundleBuilderTests: XCTestCase {

    private var workDir: URL!
    private var releaseURL: URL!
    private var folderURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        workDir = FileManager.default.temporaryDirectory.appendingPathComponent("MergedBundleBuilderTests-\(UUID().uuidString)")
        let storage = workDir.appendingPathComponent("Lingohub")
        releaseURL = storage.appendingPathComponent("update.bundle")
        folderURL = storage.appendingPathComponent("merged")
        try FileManager.default.createDirectory(at: releaseURL, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: workDir)
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makeApp(
        developmentRegion: String = "en",
        strings: [String: [String: [String: String]]],
        stringsdicts: [String: [String: [String: Any]]] = [:]
    ) throws -> (bundle: Bundle, source: MergedBundleSource) {
        let url = workDir.appendingPathComponent("App-\(UUID().uuidString).app")
        let bundle = try TestArchives.appBundle(at: url, developmentRegion: developmentRegion, strings: strings, stringsdicts: stringsdicts)
        return (bundle, MergedBundleSource(bundle: bundle))
    }

    private func writeRelease(strings: [String: [String: [String: String]]], stringsdicts: [String: [String: [String: Any]]] = [:]) throws {
        try TestArchives.write(files: TestArchives.releaseFiles(strings: strings, stringsdicts: stringsdicts), to: releaseURL)
    }

    private func build(_ source: MergedBundleSource, release: String = "release-1") throws -> MergedBundle {
        return try MergedBundleBuilder(source: source, distributionVersion: release, folder: folderURL).build(from: releaseURL)
    }

    private func strings(_ merged: MergedBundle, _ language: String, table: String = "Localizable") -> [String: String]? {
        return NSDictionary(contentsOf: merged.url.appendingPathComponent("\(language).lproj/\(table).strings")) as? [String: String]
    }

    private func stringsdict(_ merged: MergedBundle, _ language: String, table: String = "Localizable") -> [String: Any]? {
        return NSDictionary(contentsOf: merged.url.appendingPathComponent("\(language).lproj/\(table).stringsdict")) as? [String: Any]
    }

    /// Resolved by Foundation in the merged bundle's single-language view.
    private func lookup(_ key: String, in merged: MergedBundle, language: String, table: String? = nil) -> String {
        return merged.bundle(forLanguage: language).localizedString(forKey: key, value: nil, table: table)
    }

    // MARK: - Merge rules

    func testReleaseEntriesAreLaidOverAppTables() throws {
        let app = try makeApp(strings: ["en": ["Localizable": ["welcome": "Welcome (app)", "only_app": "Only in the app"]]])
        try writeRelease(strings: ["en": ["Localizable": ["welcome": "Welcome (release)", "only_release": "Only in the release"]]])

        let merged = try build(app.source)

        XCTAssertEqual(strings(merged, "en"), [
            "welcome": "Welcome (release)",
            "only_app": "Only in the app",
            "only_release": "Only in the release",
        ])
        XCTAssertEqual(lookup("welcome", in: merged, language: "en"), "Welcome (release)")
        XCTAssertEqual(lookup("only_app", in: merged, language: "en"), "Only in the app")
    }

    func testTablesTheReleaseDoesNotTouchAreCopiedUnchanged() throws {
        let app = try makeApp(strings: [
            "en": ["Localizable": ["welcome": "Welcome"], "Other": ["other": "Other (app)"]],
            "de": ["Localizable": ["welcome": "Willkommen"]],
        ])
        try writeRelease(strings: ["en": ["Localizable": ["welcome": "Welcome (release)"]]])

        let merged = try build(app.source)

        let appResources = try XCTUnwrap(app.bundle.resourceURL)
        for path in ["en.lproj/Other.strings", "de.lproj/Localizable.strings"] {
            XCTAssertEqual(
                try Data(contentsOf: merged.url.appendingPathComponent(path)),
                try Data(contentsOf: appResources.appendingPathComponent(path)),
                "\(path) must be the app's file, byte for byte"
            )
        }
    }

    func testReleaseStringReplacesAppPluralAndDeviceVariants() throws {
        // Xcode compiles a String Catalog device variation into both files: the fallback
        // in .strings and the variants in .stringsdict. Foundation prefers .stringsdict,
        // so a release key must remove the app's entry there as well.
        let app = try makeApp(
            strings: ["en": ["Localizable": ["device_key": "Click (app)"]]],
            stringsdicts: ["en": ["Localizable": [
                "device_key": ["NSStringDeviceSpecificRuleType": ["iphone": "Tap (app)", "mac": "Click on Mac (app)"]],
                "apples": TestArchives.plural(one: "%lld apple (app)", other: "%lld apples (app)"),
            ]]]
        )
        try writeRelease(strings: ["en": ["Localizable": ["device_key": "Press (release)", "apples": "Apples (release)"]]])

        let merged = try build(app.source)

        XCTAssertEqual(strings(merged, "en"), ["device_key": "Press (release)", "apples": "Apples (release)"])
        XCTAssertNil(stringsdict(merged, "en"), "No app plural or device entry may survive a release key")
        XCTAssertEqual(lookup("device_key", in: merged, language: "en"), "Press (release)")
        XCTAssertEqual(lookup("apples", in: merged, language: "en"), "Apples (release)")
    }

    func testReleasePluralReplacesAppString() throws {
        let app = try makeApp(strings: ["en": ["Localizable": ["items_count": "%lld items (app)", "welcome": "Welcome"]]])
        try writeRelease(
            strings: ["en": ["Localizable": ["welcome": "Welcome (release)"]]],
            stringsdicts: ["en": ["Localizable": ["items_count": TestArchives.plural(one: "%lld item (release)", other: "%lld items (release)")]]]
        )

        let merged = try build(app.source)

        XCTAssertEqual(strings(merged, "en"), ["welcome": "Welcome (release)"])
        XCTAssertNotNil(stringsdict(merged, "en")?["items_count"])
        let format = lookup("items_count", in: merged, language: "en")
        XCTAssertEqual(String(format: format, locale: Locale(identifier: "en"), 1), "1 item (release)")
        XCTAssertEqual(String(format: format, locale: Locale(identifier: "en"), 5), "5 items (release)")
    }

    func testAppPluralsSurviveWhenTheReleaseDoesNotDefineThem() throws {
        let app = try makeApp(
            strings: ["en": ["Localizable": ["welcome": "Welcome"]]],
            stringsdicts: ["en": ["Localizable": ["apples": TestArchives.plural(one: "%lld apple (app)", other: "%lld apples (app)")]]]
        )
        try writeRelease(strings: ["en": ["Localizable": ["welcome": "Welcome (release)"]]])

        let merged = try build(app.source)

        let format = lookup("apples", in: merged, language: "en")
        XCTAssertEqual(String(format: format, locale: Locale(identifier: "en"), 3), "3 apples (app)")
    }

    func testReleaseOnlyLanguageStartsFromTheDevelopmentLanguage() throws {
        let app = try makeApp(developmentRegion: "de", strings: [
            "en": ["Localizable": ["welcome": "Welcome", "only_app": "Only in the app (en)"]],
            "de": ["Localizable": ["welcome": "Willkommen", "only_app": "Nur in der App (de)"]],
        ])
        try writeRelease(strings: ["fr": ["Localizable": ["welcome": "Bienvenue (release)"]]])

        let merged = try build(app.source)

        XCTAssertEqual(strings(merged, "fr"), ["welcome": "Bienvenue (release)", "only_app": "Nur in der App (de)"])
        XCTAssertEqual(strings(merged, "en"), ["welcome": "Welcome", "only_app": "Only in the app (en)"])
    }

    func testReleaseOnlyTableIsAdded() throws {
        let app = try makeApp(strings: [
            "en": ["Localizable": ["welcome": "Welcome"]],
            "de": ["Localizable": ["welcome": "Willkommen"]],
        ])
        try writeRelease(strings: ["en": ["Onboarding": ["step_1": "First step (release)"]]])

        let merged = try build(app.source)

        XCTAssertEqual(lookup("step_1", in: merged, language: "en", table: "Onboarding"), "First step (release)")
        // A German lookup of the whole bundle falls back to the development language's
        // table; the German folder resolves the same on its own
        XCTAssertEqual(lookup("step_1", in: merged, language: "de", table: "Onboarding"), "First step (release)")
    }

    // MARK: - Foundation's fallback, per table file

    func testReleaseTableDoesNotHideTheAppsFallbackTable() throws {
        // The app has Settings only in its development language; a German lookup falls
        // back to it. A release adding German Settings with other keys must not hide it.
        let app = try makeApp(strings: [
            "en": ["Localizable": ["welcome": "Welcome"], "Settings": ["title": "Title (en)"]],
            "de": ["Localizable": ["welcome": "Willkommen"]],
        ])
        try writeRelease(strings: ["de": ["Settings": ["other": "Anderes (Release)"]]])

        let merged = try build(app.source)

        XCTAssertEqual(strings(merged, "de", table: "Settings"), ["title": "Title (en)", "other": "Anderes (Release)"])
        XCTAssertEqual(lookup("title", in: merged, language: "de", table: "Settings"), "Title (en)")
        if #available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *) {
            let resource = LocalizedStringResource("title", table: "Settings", locale: Locale(identifier: "de"), bundle: .atURL(merged.bundle.bundleURL))
            XCTAssertEqual(String(localized: resource), "Title (en)")
        }
    }

    func testLanguageFoldersAreSelfContained() throws {
        // Foundation's order for a table file a language lacks: its base language, Base,
        // then the development language. Each folder resolves it on its own, as the
        // single-language views that serve setLanguage(_:) require.
        let app = try makeApp(strings: [
            "Base": ["Settings": ["title": "Title (Base)"]],
            "en": ["Localizable": ["welcome": "Welcome"], "Settings": ["title": "Title (en)"], "Help": ["faq": "FAQ (en)"]],
            "de": ["Localizable": ["welcome": "Willkommen"], "Help": ["faq": "FAQ (de)"]],
            "de-AT": ["Localizable": ["welcome": "Servus"]],
        ])
        try writeRelease(strings: ["en": ["Localizable": ["welcome": "Welcome (release)"]]])

        let merged = try build(app.source)

        XCTAssertEqual(lookup("title", in: merged, language: "de", table: "Settings"), "Title (Base)", "Base before the development language")
        XCTAssertEqual(lookup("faq", in: merged, language: "de-AT", table: "Help"), "FAQ (de)", "The base language first")
        XCTAssertEqual(lookup("title", in: merged, language: "de-AT", table: "Settings"), "Title (Base)")
        XCTAssertEqual(lookup("welcome", in: merged, language: "de-AT"), "Servus")
    }

    func testNonlocalizedAppTablesAreTheBase() throws {
        // Tables directly in the app's resources, outside any .lproj, win over localized
        // ones in Foundation; they are the base the release is laid over
        let app = try makeApp(strings: ["en": ["Other": ["x": "y"]]])
        let resources = try XCTUnwrap(app.bundle.resourceURL)
        try PropertyListSerialization.data(fromPropertyList: ["welcome": "Welcome (root)", "only_app": "Root fallback"], format: .binary, options: 0)
            .write(to: resources.appendingPathComponent("Localizable.strings"))
        try writeRelease(strings: ["en": ["Localizable": ["welcome": "Welcome (release)"]]])

        let merged = try build(app.source)

        XCTAssertEqual(lookup("welcome", in: merged, language: "en"), "Welcome (release)")
        XCTAssertEqual(lookup("only_app", in: merged, language: "en"), "Root fallback")
        XCTAssertEqual(String(localized: "only_app", bundle: merged.bundle), "Root fallback")
        XCTAssertFalse(FileManager.default.fileExists(atPath: merged.url.appendingPathComponent("Localizable.strings").path), "A root table would hide every language's merged table")
    }

    func testMacOSMetadataInTheReleaseIsIgnored() throws {
        let app = try makeApp(strings: ["en": ["Localizable": ["welcome": "Welcome"]]])
        try writeRelease(strings: ["en": ["Localizable": ["welcome": "Welcome (release)"]]])
        try TestArchives.write(files: ["en.lproj/._Localizable.strings": Data([0x00, 0x05, 0x16, 0x07])], to: releaseURL)

        let merged = try build(app.source)

        XCTAssertEqual(strings(merged, "en"), ["welcome": "Welcome (release)"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: merged.url.appendingPathComponent("en.lproj/._Localizable.strings").path))
    }

    // MARK: - Bundle layout

    func testInfoPlistCarriesDevelopmentRegionAndManifest() throws {
        let app = try makeApp(developmentRegion: "de", strings: [
            "en": ["Localizable": ["welcome": "Welcome"]],
            "de": ["Localizable": ["welcome": "Willkommen"]],
        ])
        try writeRelease(strings: ["de": ["Localizable": ["welcome": "Willkommen (Release)"]]])

        let merged = try build(app.source, release: "release-42")

        XCTAssertEqual(merged.bundle.developmentLocalization, "de")
        XCTAssertEqual(Set(merged.bundle.localizations), ["en", "de"])
        XCTAssertEqual(Set(merged.languageBundles.keys), ["en", "de"])
        XCTAssertEqual(merged.manifest, MergedBundleManifest(distributionVersion: "release-42", sourceFingerprint: app.source.fingerprint()))
        XCTAssertEqual(MergedBundleManifest(bundleURL: merged.url), merged.manifest)
    }

    func testEveryBuildGetsAFreshPath() throws {
        // Foundation caches bundles and their string tables by path: reusing a path for
        // new content would serve the previous content.
        let app = try makeApp(strings: ["en": ["Localizable": ["welcome": "Welcome"]]])
        try writeRelease(strings: ["en": ["Localizable": ["welcome": "Welcome (release)"]]])

        let first = try build(app.source)
        let second = try build(app.source)

        XCTAssertNotEqual(first.url, second.url)
        XCTAssertTrue(first.url.lh_isDirectory)
        XCTAssertTrue(second.url.lh_isDirectory)
    }

    // MARK: - Failures

    func testMissingReleaseFailsWithoutCreatingTheFolder() throws {
        let app = try makeApp(strings: ["en": ["Localizable": ["welcome": "Welcome"]]])
        try FileManager.default.removeItem(at: releaseURL)

        XCTAssertThrowsError(try build(app.source)) { error in
            guard case MergedBundleBuilder.BuildError.releaseMissing = error else {
                return XCTFail("Expected releaseMissing, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folderURL.path))
    }

    func testUnreadableAppTableFailsTheBuildWithoutLeftovers() throws {
        let app = try makeApp(strings: ["en": ["Localizable": ["welcome": "Welcome"]]])
        let appTable = try XCTUnwrap(app.bundle.resourceURL).appendingPathComponent("en.lproj/Localizable.strings")
        try Data("{{{{ not a strings file".utf8).write(to: appTable)
        try writeRelease(strings: ["en": ["Localizable": ["welcome": "Welcome (release)"]]])

        XCTAssertThrowsError(try build(app.source)) { error in
            guard case MergedBundleBuilder.BuildError.unreadableTable = error else {
                return XCTFail("Expected unreadableTable, got \(error)")
            }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folderURL.path), [], "A failed build must not leave staging or partial bundles")
    }

    // MARK: - Fingerprint and store

    func testFingerprintTracksTheAppTables() throws {
        let app = try makeApp(strings: ["en": ["Localizable": ["welcome": "Welcome"]]])
        let fingerprint = app.source.fingerprint()
        XCTAssertEqual(app.source.fingerprint(), fingerprint, "Unchanged tables must give the same fingerprint")

        let appTable = try XCTUnwrap(app.bundle.resourceURL).appendingPathComponent("en.lproj/Localizable.strings")
        let changed = try PropertyListSerialization.data(fromPropertyList: ["welcome": "Welcome to the new build"], format: .binary, options: 0)
        try changed.write(to: appTable)
        let afterLocalizedChange = app.source.fingerprint()
        XCTAssertNotEqual(afterLocalizedChange, fingerprint)

        // Nonlocalized tables at the resources root count too
        let rootTable = try XCTUnwrap(app.bundle.resourceURL).appendingPathComponent("Localizable.strings")
        try PropertyListSerialization.data(fromPropertyList: ["only_app": "Root"], format: .binary, options: 0).write(to: rootTable)
        XCTAssertNotEqual(app.source.fingerprint(), afterLocalizedChange)
    }

    func testReusableRequiresTheExactManifest() throws {
        let app = try makeApp(strings: ["en": ["Localizable": ["welcome": "Welcome"]]])
        try writeRelease(strings: ["en": ["Localizable": ["welcome": "Welcome (release)"]]])
        let merged = try build(app.source, release: "release-1")
        let fingerprint = app.source.fingerprint()

        XCTAssertEqual(MergedBundle.reusable(matching: MergedBundleManifest(distributionVersion: "release-1", sourceFingerprint: fingerprint), in: folderURL)?.url, merged.url)
        XCTAssertNil(MergedBundle.reusable(matching: MergedBundleManifest(distributionVersion: "release-2", sourceFingerprint: fingerprint), in: folderURL))
        XCTAssertNil(MergedBundle.reusable(matching: MergedBundleManifest(distributionVersion: "release-1", sourceFingerprint: "other"), in: folderURL))
        XCTAssertNil(MergedBundle.reusable(matching: MergedBundleManifest(distributionVersion: "release-1", sourceFingerprint: fingerprint, formatVersion: 0), in: folderURL))
    }

    func testRemoveAllKeepsOnlyTheKeptBundles() throws {
        let app = try makeApp(strings: ["en": ["Localizable": ["welcome": "Welcome"]]])
        try writeRelease(strings: ["en": ["Localizable": ["welcome": "Welcome (release)"]]])
        let first = try build(app.source)
        let second = try build(app.source)
        let third = try build(app.source)
        let leftover = folderURL.appendingPathComponent(LingoHubConstants.stagingDirectoryPrefix + "crashed")
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)

        MergedBundle.removeAll(in: folderURL, keeping: [second.url, third.url])

        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: folderURL.path)), [second.url.lastPathComponent, third.url.lastPathComponent])
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.url.path))
    }
}

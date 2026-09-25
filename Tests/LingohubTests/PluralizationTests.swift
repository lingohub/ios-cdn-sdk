//
//  PluralizationTests.swift
//
//  Verifies the README's claim that `.stringsdict` plurals work through the
//  swizzled `NSLocalizedString` path - the one area the 2026 review flagged as
//  claimed-but-untested. Uses the same file shape the live CDN delivers
//  (per-language `.lproj` folders containing `.strings` + `.stringsdict`).
//

import XCTest
@testable import Lingohub

@MainActor
final class PluralizationTests: XCTestCase {
    let sut: LingoHubSDK = LingoHubSDK.testInstance()

    private var testStorageRoot: URL!
    private var auxDir: URL!

    @MainActor
    override func setUp() async throws {
        try await super.setUp()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LingohubPluralTests-\(UUID().uuidString)")
        testStorageRoot = root
        auxDir = root.appendingPathComponent("aux")
        try FileManager.default.createDirectory(at: auxDir, withIntermediateDirectories: true)
        sut.cacheManager.storageRootOverride = root.appendingPathComponent("current")
        sut.cacheManager.legacyStorageRootOverride = root.appendingPathComponent("legacy")
        sut.reset()
    }

    @MainActor
    override func tearDown() async throws {
        await sut.waitForMergedBundleWork()
        sut.reset()
        Bundle.deswizzle()
        try await super.tearDown()
        sut.cacheManager.storageRootOverride = nil
        sut.cacheManager.legacyStorageRootOverride = nil
        try? FileManager.default.removeItem(at: testStorageRoot)
    }

    /// The fixture release (update.zip) contains a "persons" plural in
    /// Localizable.stringsdict for en and de - resolve it through the swizzled
    /// system path with both languages and both plural branches.
    func testStringsdictPluralsResolveThroughSwizzledPath() async throws {
        sut.configureForTests()
        sut.setLanguage("en")
        await sut.installUpdatedBundle()
        sut.swizzleBundle(Bundle.module)

        let patternEn = NSLocalizedString("persons", tableName: nil, bundle: Bundle.module, value: "", comment: "")
        XCTAssertNotEqual(patternEn, "persons", "Plural key must resolve from the update bundle")
        XCTAssertEqual(String.localizedStringWithFormat(patternEn, 1), "One person")
        XCTAssertEqual(String.localizedStringWithFormat(patternEn, 5), "5 persons")

        // The documented caveat: the manual API reads .strings only
        XCTAssertNil(sut.localizedString(forKey: "persons"))

        sut.setLanguage("de")
        let patternDe = NSLocalizedString("persons", tableName: nil, bundle: Bundle.module, value: "", comment: "")
        XCTAssertEqual(String.localizedStringWithFormat(patternDe, 1), "Eine Person")
        XCTAssertEqual(String.localizedStringWithFormat(patternDe, 5), "5 Personen")
    }

    /// Non-default table, same file shape the live CDN ships (e.g. strings.strings
    /// + strings.stringsdict): plurals must resolve for explicit table names too.
    func testStringsdictPluralsResolveForNonDefaultTable() async throws {
        sut.configureForTests()
        sut.setLanguage("de")
        await sut.installUpdatedBundle()
        sut.swizzleBundle(Bundle.module)

        // Fixture: de.lproj/Test.stringsdict "ref_invite_format" (one/other)
        let pattern = NSLocalizedString("ref_invite_format", tableName: "Test", bundle: Bundle.module, value: "", comment: "")
        XCTAssertNotEqual(pattern, "ref_invite_format")
        XCTAssertEqual(String.localizedStringWithFormat(pattern, 1), "Freund einladen")
        XCTAssertEqual(String.localizedStringWithFormat(pattern, 4), "4Freunde einladen")
    }

    /// Regression (lingohub/organization#2354): Foundation caches bundles and their
    /// string tables by path. When every release was installed at the same path, a
    /// second release in the same process kept serving the first release's `.stringsdict`
    /// plurals (and missed tables the first release did not have) until the next launch,
    /// while `.strings` keys updated.
    func testSecondReleaseInstalledInTheSameProcessServesItsPlurals() async throws {
        sut.configureForTests()
        sut.setLanguage("en")
        sut.swizzleBundle(Bundle.module)

        for release in ["first", "second"] {
            var files: [String: Data] = [
                "en.lproj/Localizable.strings": Data("\"plain\" = \"plain \(release)\";".utf8),
                "en.lproj/Localizable.stringsdict": try pluralStringsdict(key: "things", one: "%lld thing \(release)", other: "%lld things \(release)"),
            ]
            if release == "second" {
                files["en.lproj/Extra.strings"] = Data("\"extra\" = \"extra \(release)\";".utf8)
            }
            let archive = auxDir.appendingPathComponent("\(release).zip")
            try TestArchives.zip(files: files, to: archive)
            try await sut.installArchive(at: archive, identifier: "release-\(release)", appVersion: TestConstants.appVersion)

            let pattern = NSLocalizedString("things", tableName: nil, bundle: Bundle.module, value: "", comment: "")
            XCTAssertEqual(String(format: pattern, locale: Locale(identifier: "en"), 5), "5 things \(release)", "Plural after installing the \(release) release")
            XCTAssertEqual(NSLocalizedString("plain", tableName: nil, bundle: Bundle.module, value: "", comment: ""), "plain \(release)")
        }
        XCTAssertEqual(NSLocalizedString("extra", tableName: "Extra", bundle: Bundle.module, value: "", comment: ""), "extra second", "A table only the second release has")
    }

    private func pluralStringsdict(key: String, one: String, other: String) throws -> Data {
        let entry: [String: Any] = [
            "NSStringLocalizedFormatKey": "%#@count@",
            "count": [
                "NSStringFormatSpecTypeKey": "NSStringPluralRuleType",
                "NSStringFormatValueTypeKey": "lld",
                "one": one,
                "other": other,
            ] as [String: Any],
        ]
        return try PropertyListSerialization.data(fromPropertyList: [key: entry], format: .xml, options: 0)
    }

    /// The hard case: languages whose plural rules differ from the device language.
    /// Foundation selects the plural CATEGORY at *format* time from the formatting
    /// locale — `String.localizedStringWithFormat` uses `Locale.current`, which in a
    /// stock app always matches the served language. With a `setLanguage` override,
    /// apps must format with the override's locale (the recipe the README documents);
    /// this test proves the pattern served from the update bundle then resolves every
    /// Russian category correctly (1 → one, 3 → few, 5 → many, 21 → one).
    func testPluralCategoriesResolveWithOverrideLanguageLocale() async throws {
        let stringsdict = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>apples</key>
            <dict>
                <key>NSStringLocalizedFormatKey</key>
                <string>%#@value@</string>
                <key>value</key>
                <dict>
                    <key>NSStringFormatSpecTypeKey</key>
                    <string>NSStringPluralRuleType</string>
                    <key>NSStringFormatValueTypeKey</key>
                    <string>d</string>
                    <key>one</key>
                    <string>%d yabloko</string>
                    <key>few</key>
                    <string>%d yabloka</string>
                    <key>many</key>
                    <string>%d yablok</string>
                    <key>other</key>
                    <string>%d apples-other</string>
                </dict>
            </dict>
        </dict>
        </plist>
        """
        let archive = auxDir.appendingPathComponent("ru-release.zip")
        try TestArchives.zip(files: ["ru.lproj/Localizable.stringsdict": Data(stringsdict.utf8)], to: archive)

        sut.configureForTests()
        try await sut.installArchive(at: archive, identifier: "ru-release", appVersion: TestConstants.appVersion)
        sut.setLanguage("ru")
        sut.swizzleBundle(Bundle.module)

        let pattern = NSLocalizedString("apples", tableName: nil, bundle: Bundle.module, value: "", comment: "")
        XCTAssertNotEqual(pattern, "apples", "Plural key must resolve from the update bundle")

        // Formatting with the override language's locale selects the right category
        // on any host system - this is what apps using setLanguage must do for
        // languages with diverging plural rules.
        let russian = Locale(identifier: "ru")
        func format(_ count: Int) -> String {
            return NSString(format: pattern as NSString, locale: russian, count) as String
        }
        XCTAssertEqual(format(1), "1 yabloko", "1 must select the 'one' category")
        XCTAssertEqual(format(3), "3 yabloka", "3 must select the 'few' category (Russian rules)")
        XCTAssertEqual(format(5), "5 yablok", "5 must select the 'many' category (Russian rules)")
        XCTAssertEqual(format(21), "21 yabloko", "21 must select the 'one' category (Russian rules)")
        // The form the README shows
        XCTAssertEqual(String(format: pattern, locale: russian, 3), "3 yabloka")
    }
}

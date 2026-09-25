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
        localizations: [String]? = nil,
        strings: [String: [String: [String: String]]],
        stringsdicts: [String: [String: [String: Any]]] = [:]
    ) throws -> (bundle: Bundle, source: MergedBundleSource) {
        let url = workDir.appendingPathComponent("App-\(UUID().uuidString).app")
        let bundle = try TestArchives.appBundle(at: url, developmentRegion: developmentRegion, localizations: localizations, strings: strings, stringsdicts: stringsdicts)
        return (bundle, MergedBundleSource(bundle: bundle))
    }

    /// Writes a table directly into the app's resources, outside any `.lproj`, as Xcode
    /// ships a table that was never localized.
    private func writeNonlocalizedTable(_ entries: [String: String], named name: String = "Localizable", into app: Bundle) throws {
        let url = try XCTUnwrap(app.resourceURL).appendingPathComponent(name + ".strings")
        try PropertyListSerialization.data(fromPropertyList: entries, format: .binary, options: 0).write(to: url)
    }

    private func writeRelease(strings: [String: [String: [String: String]]], stringsdicts: [String: [String: [String: Any]]] = [:]) throws {
        try TestArchives.write(files: TestArchives.releaseFiles(strings: strings, stringsdicts: stringsdicts), to: releaseURL)
    }

    private func build(_ source: MergedBundleSource, release: String = "release-1") throws -> MergedBundle {
        return try MergedBundleBuilder(source: source, distributionVersion: release, folder: folderURL).build(from: releaseURL)
    }

    /// Resolved by Foundation for a `LocalizedStringResource` in `locale`, against the
    /// bundle at `bundleURL`: the lookup Swift-native APIs make.
    @available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *)
    private func resolve(_ key: String, table: String? = nil, locale: String, in bundleURL: URL) -> String {
        let resource = LocalizedStringResource(String.LocalizationValue(key), table: table, locale: Locale(identifier: locale), bundle: .atURL(bundleURL))
        return String(localized: resource)
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
        try writeNonlocalizedTable(["welcome": "Welcome (root)", "only_app": "Root fallback"], into: app.bundle)
        try writeRelease(strings: ["en": ["Localizable": ["welcome": "Welcome (release)"]]])

        let merged = try build(app.source)

        XCTAssertEqual(lookup("welcome", in: merged, language: "en"), "Welcome (release)")
        XCTAssertEqual(lookup("only_app", in: merged, language: "en"), "Root fallback")
        XCTAssertEqual(String(localized: "only_app", bundle: merged.bundle), "Root fallback")
        XCTAssertFalse(FileManager.default.fileExists(atPath: merged.url.appendingPathComponent("Localizable.strings").path), "A root table would hide every language's merged table")
    }

    func testNonlocalizedTablesServeEveryLanguageTheAppSupports() throws {
        // Foundation serves a table outside any .lproj in every language, including the
        // development language the app has no folder for. The merged bundle serves it
        // from language folders only, so it needs one for every language the app
        // supports, whether or not the release has it.
        let app = try makeApp(localizations: ["en", "de"], strings: [:])
        try writeNonlocalizedTable(["welcome": "Welcome from root"], into: app.bundle)
        try writeRelease(strings: ["fr": ["Localizable": ["welcome": "Bonjour (release)"]]])

        let merged = try build(app.source)

        XCTAssertEqual(Set(merged.languageBundles.keys), ["en", "de", "fr"])
        XCTAssertEqual(lookup("welcome", in: merged, language: "en"), "Welcome from root")
        XCTAssertEqual(lookup("welcome", in: merged, language: "de"), "Welcome from root")
        XCTAssertEqual(lookup("welcome", in: merged, language: "fr"), "Bonjour (release)")
        if #available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *) {
            for locale in ["en", "de", "ja"] {
                XCTAssertEqual(resolve("welcome", locale: locale, in: app.bundle.bundleURL), "Welcome from root", "App, \(locale)")
                XCTAssertEqual(resolve("welcome", locale: locale, in: merged.bundle.bundleURL), "Welcome from root", "Merged bundle, \(locale)")
            }
        }
    }

    func testScriptRegionFallsBackToItsScript() throws {
        // zh-Hant-TW falls back to zh-Hant, never to zh or the development language
        guard #available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *) else {
            throw XCTSkip("LocalizedStringResource requires iOS 16 / macOS 13")
        }
        let app = try makeApp(strings: [
            "en": ["Settings": ["title": "English settings"]],
            "zh-Hant": ["Settings": ["title": "Traditional settings"]],
            "zh-Hant-TW": ["Localizable": ["welcome": "Taiwan welcome"]],
        ])
        XCTAssertEqual(resolve("title", table: "Settings", locale: "zh-Hant-TW", in: app.bundle.bundleURL), "Traditional settings")
        try writeRelease(strings: ["zh-Hant-TW": ["Localizable": ["welcome": "Taiwan release"]]])

        let merged = try build(app.source)

        XCTAssertEqual(resolve("title", table: "Settings", locale: "zh-Hant-TW", in: merged.bundle.bundleURL), "Traditional settings")
        XCTAssertEqual(lookup("title", in: merged, language: "zh-Hant-TW", table: "Settings"), "Traditional settings")
        XCTAssertEqual(lookup("welcome", in: merged, language: "zh-Hant-TW"), "Taiwan release")
    }

    func testFallbackMatchesFoundationForEveryLanguageFamily() throws {
        // Foundation matches a language to its script and CLDR parents, regional siblings
        // (the first listed of equally good ones), and legacy codes (es-MX → es-419,
        // pt-AO → pt-PT, de-AT → de-CH, he → iw), and stops at the language's own folder
        // when the app has one. The merged bundle must resolve a table the language lacks
        // exactly as the app does, wherever the app resolves it at all (where it returns
        // the key, the merged bundle may fall back further).
        guard #available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *) else {
            throw XCTSkip("LocalizedStringResource requires iOS 16 / macOS 13")
        }
        let families: [(language: String, settings: [String: String])] = [
            ("zh-Hant-TW", ["zh": "Generic Chinese", "zh-Hans": "Simplified", "zh-Hant": "Traditional"]),
            ("zh-Hant-TW", ["zh-TW": "Legacy Taiwan"]),
            ("es-MX", ["es": "Spanish", "es-419": "Latin American"]),
            ("pt-AO", ["pt-BR": "Brazilian", "pt-PT": "European"]),
            ("de-AT", ["de-CH": "Swiss"]),
            ("fr-BE", ["fr-CA": "Canadian French", "fr-CH": "Swiss French"]),
            ("he", ["iw": "Hebrew (iw)"]),
        ]
        var compared = 0
        for (language, settings) in families {
            for appHasLanguage in [false, true] {
                var strings: [String: [String: [String: String]]] = ["en": ["Settings": ["title": "English"]]]
                for (localization, title) in settings {
                    strings[localization] = ["Settings": ["title": title]]
                }
                if appHasLanguage {
                    strings[language] = ["Localizable": ["welcome": "Welcome (app)"]]
                }
                let app = try makeApp(strings: strings)
                let release = workDir.appendingPathComponent("release-\(UUID().uuidString)")
                try TestArchives.write(files: TestArchives.releaseFiles(strings: [language: ["Localizable": ["welcome": "Welcome (release)"]]]), to: release)
                let merged = try MergedBundleBuilder(source: app.source, distributionVersion: "release-1", folder: folderURL).build(from: release)

                let context = "\(language), \(appHasLanguage ? "with" : "without") the app's own folder"
                let native = resolve("title", table: "Settings", locale: language, in: app.bundle.bundleURL)
                guard native != "title" else { continue }
                compared += 1
                XCTAssertEqual(resolve("title", table: "Settings", locale: language, in: merged.bundle.bundleURL), native, context)
                XCTAssertEqual(lookup("title", in: merged, language: language, table: "Settings"), native, "Language view, \(context)")
            }
        }
        XCTAssertGreaterThanOrEqual(compared, families.count, "Every family resolves natively at least without its own folder")
    }

    func testReleaseUpdatesReachTheLanguagesThatFallBackToThem() throws {
        // A table a language lacks resolves in the language it falls back to, and the
        // release's update of that language must reach it there too. Only for languages
        // the lookup reaches before the app's own table: an update of a fallback never
        // replaces the language's own translation.
        let app = try makeApp(strings: [
            "en": ["Localizable": ["welcome": "Welcome"], "Settings": ["title": "Title", "subtitle": "Subtitle"], "Help": ["faq": "FAQ"]],
            "de": ["Localizable": ["welcome": "Willkommen"], "Settings": ["title": "Titel", "subtitle": "Untertitel"]],
            "de-AT": ["Localizable": ["welcome": "Servus"]],
        ])
        try writeRelease(strings: [
            "de": ["Settings": ["title": "Titel (Release)"]],
            "en": ["Settings": ["title": "Title (release)", "subtitle": "Subtitle (release)"], "Help": ["faq": "FAQ (release)"]],
        ])

        let merged = try build(app.source)

        XCTAssertEqual(lookup("title", in: merged, language: "de-AT", table: "Settings"), "Titel (Release)")
        XCTAssertEqual(lookup("faq", in: merged, language: "de", table: "Help"), "FAQ (release)")
        XCTAssertEqual(lookup("faq", in: merged, language: "de-AT", table: "Help"), "FAQ (release)")
        XCTAssertEqual(lookup("subtitle", in: merged, language: "de", table: "Settings"), "Untertitel")
        XCTAssertEqual(lookup("subtitle", in: merged, language: "de-AT", table: "Settings"), "Untertitel")
        XCTAssertEqual(lookup("welcome", in: merged, language: "de-AT"), "Servus")
        if #available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *) {
            XCTAssertEqual(resolve("title", table: "Settings", locale: "de-AT", in: merged.bundle.bundleURL), "Titel (Release)")
        }
    }

    func testReleaseUpdatesReachEachFileOfATableOnItsOwn() throws {
        // A plain lookup resolves a table's .strings and .stringsdict each on its own:
        // de-AT with only its own .strings still reads the plurals from de, and the other
        // way round. The release's update of de reaches the file de-AT reads from de, and
        // never the file de-AT has itself.
        let app = try makeApp(
            strings: [
                "de-AT": ["Localizable": ["welcome": "Servus"]],
                "de": ["Settings": ["title": "Titel (App)"]],
            ],
            stringsdicts: [
                "de": ["Localizable": ["apples": TestArchives.plural(one: "%lld Apfel (App)", other: "%lld Äpfel (App)")]],
                "de-AT": ["Settings": ["items": TestArchives.plural(one: "%lld Stück (AT)", other: "%lld Stück (AT)")]],
            ]
        )
        try writeRelease(
            strings: ["de": [
                "Localizable": ["welcome": "Willkommen (Release)"],
                "Settings": ["title": "Titel (Release)"],
            ]],
            stringsdicts: ["de": [
                "Localizable": ["apples": TestArchives.plural(one: "%lld Apfel (Release)", other: "%lld Äpfel (Release)")],
                "Settings": ["items": TestArchives.plural(one: "%lld Stück (Release)", other: "%lld Stück (Release)")],
            ]]
        )

        let merged = try build(app.source)

        let german = Locale(identifier: "de")
        XCTAssertEqual(String(format: lookup("apples", in: merged, language: "de-AT"), locale: german, 3), "3 Äpfel (Release)")
        XCTAssertEqual(lookup("title", in: merged, language: "de-AT", table: "Settings"), "Titel (Release)")
        XCTAssertEqual(lookup("welcome", in: merged, language: "de-AT"), "Servus")
        XCTAssertEqual(String(format: lookup("items", in: merged, language: "de-AT", table: "Settings"), locale: german, 3), "3 Stück (AT)")
    }

    func testReleaseCanChangeTheFormatOfAFallbackEntry() throws {
        // de-AT reads apples from de. A release of de that turns the plural into a plain
        // string (or the other way round) must replace it in de-AT too: dropping the old
        // entry without adding the new one would leave the raw key.
        let app = try makeApp(
            strings: [
                "de-AT": ["Localizable": ["welcome": "Servus"]],
                "de": ["Settings": ["pears": "Birnen (App)"]],
            ],
            stringsdicts: [
                "de": ["Localizable": ["apples": TestArchives.plural(one: "%lld Apfel (App)", other: "%lld Äpfel (App)")]],
                "de-AT": ["Settings": ["items": TestArchives.plural(one: "%lld Stück (AT)", other: "%lld Stück (AT)")]],
            ]
        )
        let german = Locale(identifier: "de")
        try writeRelease(strings: ["de-AT": ["Localizable": ["welcome": "Servus"]]])
        let before = try build(app.source)
        XCTAssertEqual(String(format: lookup("apples", in: before, language: "de-AT"), locale: german, 3), "3 Äpfel (App)")
        XCTAssertEqual(lookup("pears", in: before, language: "de-AT", table: "Settings"), "Birnen (App)")

        try FileManager.default.removeItem(at: releaseURL)
        try writeRelease(
            strings: ["de": ["Localizable": ["apples": "Äpfel (Release)"]]],
            stringsdicts: ["de": ["Settings": ["pears": TestArchives.plural(one: "%lld Birne (Release)", other: "%lld Birnen (Release)")]]]
        )
        let after = try build(app.source)

        XCTAssertEqual(lookup("apples", in: after, language: "de-AT"), "Äpfel (Release)")
        XCTAssertEqual(String(format: lookup("pears", in: after, language: "de-AT", table: "Settings"), locale: german, 3), "3 Birnen (Release)")
        XCTAssertEqual(lookup("welcome", in: after, language: "de-AT"), "Servus")
        XCTAssertEqual(String(format: lookup("items", in: after, language: "de-AT", table: "Settings"), locale: german, 3), "3 Stück (AT)")
    }

    func testKeysALanguageLacksComeFromTheReleaseOfItsFallback() throws {
        // A key the app has in no file de-AT reads comes from the closest language whose
        // release has it, and never from the development language while de-AT has the table
        let app = try makeApp(strings: [
            "en": ["Localizable": ["welcome": "Welcome"]],
            "de": ["Localizable": ["welcome": "Willkommen"]],
            "de-AT": ["Localizable": ["welcome": "Servus"]],
        ])
        try writeRelease(strings: [
            "de": ["Localizable": ["goodbye": "Tschüss (Release)"]],
            "en": ["Localizable": ["goodbye": "Goodbye (release)", "thanks": "Thanks (release)"]],
        ])

        let merged = try build(app.source)

        XCTAssertEqual(lookup("goodbye", in: merged, language: "de-AT"), "Tschüss (Release)")
        XCTAssertEqual(lookup("thanks", in: merged, language: "de-AT"), "thanks")
        XCTAssertEqual(lookup("welcome", in: merged, language: "de-AT"), "Servus")
    }

    func testDevelopmentLanguageFillsInOnlyTablesALanguageLacks() throws {
        // Foundation falls back to the development language for a table the language has
        // no file of, never for a single file of it. An English .stringsdict must not
        // join German's own table: its plural would override the German string.
        let app = try makeApp(
            strings: [
                "en": ["Localizable": ["welcome": "Welcome"]],
                "de": ["Localizable": ["welcome": "Willkommen", "apples": "Äpfel"]],
            ],
            stringsdicts: ["en": ["Localizable": ["apples": TestArchives.plural(one: "%lld apple", other: "%lld apples")]]]
        )
        try writeRelease(strings: ["de": ["Localizable": ["welcome": "Willkommen (Release)"]]])

        let merged = try build(app.source)

        XCTAssertEqual(lookup("apples", in: merged, language: "de"), "Äpfel")
        XCTAssertEqual(lookup("welcome", in: merged, language: "de"), "Willkommen (Release)")
        XCTAssertNil(stringsdict(merged, "de"))
        if #available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *) {
            XCTAssertEqual(resolve("apples", locale: "de", in: app.bundle.bundleURL), "Äpfel")
            XCTAssertEqual(resolve("apples", locale: "de", in: merged.bundle.bundleURL), "Äpfel")
        }
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

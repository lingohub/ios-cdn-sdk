//
//  LingoHubBundleTests.swift
//
//  Serving downloaded releases to Swift-native lookup APIs through `Bundle.lingohub`:
//  every API of the README's coverage table, app-bundle fallback, plurals, language
//  switching, launch-time restore, and release deactivation.
//

import XCTest
@testable import Lingohub
#if canImport(SwiftUI)
import SwiftUI
#endif

@available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *)
@MainActor
final class LingoHubBundleTests: XCTestCase {
    let sut: LingoHubSDK = LingoHubSDK.testInstance()

    private var testStorageRoot: URL!
    private var auxDir: URL!
    /// Stands in for `Bundle.main`: the app's bundled strings.
    private var appBundle: Bundle!

    @MainActor
    override func setUp() async throws {
        try await super.setUp()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LingohubBundleTests-\(UUID().uuidString)")
        testStorageRoot = root
        auxDir = root.appendingPathComponent("aux")
        try FileManager.default.createDirectory(at: auxDir, withIntermediateDirectories: true)
        sut.cacheManager.storageRootOverride = root.appendingPathComponent("current")
        sut.cacheManager.legacyStorageRootOverride = root.appendingPathComponent("legacy")
        appBundle = try makeAppBundle()
        sut.cacheManager.baseBundleOverride = appBundle
        sut.reset()
    }

    @MainActor
    override func tearDown() async throws {
        await sut.waitForMergedBundleWork()
        sut.reset()
        Bundle.deswizzle()
        sut.cacheManager.baseBundleOverride = nil
        try await super.tearDown()
        sut.cacheManager.storageRootOverride = nil
        sut.cacheManager.legacyStorageRootOverride = nil
        try? FileManager.default.removeItem(at: testStorageRoot)
    }

    // MARK: - Fixtures

    /// English (the development language) and German, with a plural in each.
    private func makeAppBundle() throws -> Bundle {
        return try TestArchives.appBundle(
            at: auxDir.appendingPathComponent("App.app"),
            strings: [
                "en": [
                    "Localizable": ["welcome": "Welcome (app)", "only_app": "Only in the app", "greeting": "Hello %@ (app)"],
                    "Settings": ["title": "Settings (app)"],
                ],
                "de": [
                    "Localizable": ["welcome": "Willkommen (App)", "only_app": "Nur in der App", "greeting": "Hallo %@ (App)"],
                    "Settings": ["title": "Einstellungen (App)"],
                ],
            ],
            stringsdicts: [
                "en": ["Localizable": ["%lld apples": TestArchives.plural(one: "%lld apple (app)", other: "%lld apples (app)")]],
                "de": ["Localizable": ["%lld apples": TestArchives.plural(one: "%lld Apfel (App)", other: "%lld Äpfel (App)")]],
            ]
        )
    }

    /// A release as the CDN ships it: new en/de translations, a plural, and French, a
    /// language the app bundle does not have.
    private func installRelease(_ identifier: String = "release-1", welcome: String = "Welcome (release)") async throws {
        let archive = auxDir.appendingPathComponent("\(identifier).zip")
        let files = try TestArchives.releaseFiles(
            strings: [
                "en": ["Localizable": ["welcome": welcome, "only_release": "Only in the release", "greeting": "Hello %@ (release)", "markdown": "**Bold** (release)"]],
                "de": ["Localizable": ["welcome": "Willkommen (Release)", "greeting": "Hallo %@ (Release)"]],
                "fr": ["Localizable": ["welcome": "Bienvenue (release)"]],
            ],
            stringsdicts: [
                "en": ["Localizable": ["%lld items": TestArchives.plural(one: "%lld item (release)", other: "%lld items (release)")]],
                "de": ["Localizable": ["%lld items": TestArchives.plural(one: "%lld Ding (Release)", other: "%lld Dinge (Release)")]],
            ]
        )
        try TestArchives.zip(files: files, to: archive)
        try await sut.installArchive(at: archive, identifier: identifier, appVersion: TestConstants.appVersion)
    }

    private var mergedBundleURL: URL? {
        return sut.cacheManager.currentSnapshot?.mergedBundle?.url
    }

    private func mergedFolderContents() throws -> Set<String> {
        let folder = try XCTUnwrap(sut.cacheManager.mergedBundlesFolderUrl)
        return Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
    }

    // MARK: - Lookup APIs

    func testLingohubIsTheMainBundleWithoutARelease() {
        sut.configureForTests()

        XCTAssertTrue(Bundle.lingohub === Bundle.main)
    }

    func testStringLookupsServeTheReleaseWithAppFallback() async throws {
        sut.configureForTests()
        sut.setLanguage("en")
        try await installRelease()
        let name = "Ann"

        XCTAssertEqual(String(localized: "welcome", bundle: .lingohub), "Welcome (release)")
        XCTAssertEqual(String(localized: "only_release", bundle: .lingohub), "Only in the release")
        XCTAssertEqual(String(localized: "only_app", bundle: .lingohub), "Only in the app", "Keys the release lacks resolve to the bundled strings")
        XCTAssertEqual(String(localized: "title", table: "Settings", bundle: .lingohub), "Settings (app)", "Tables the release lacks resolve to the bundled tables")
        XCTAssertEqual(String(localized: "greeting", defaultValue: "Hello \(name)", bundle: .lingohub), "Hello Ann (release)")
        XCTAssertEqual(String(localized: "missing_everywhere", bundle: .lingohub), "missing_everywhere")
        XCTAssertEqual(NSLocalizedString("welcome", bundle: .lingohub, comment: ""), "Welcome (release)")
    }

    func testLanguageOverrideSelectsTheServedLanguage() async throws {
        sut.configureForTests()
        try await installRelease()

        sut.setLanguage("de")
        XCTAssertEqual(String(localized: "welcome", bundle: .lingohub), "Willkommen (Release)")
        XCTAssertEqual(String(localized: "only_app", bundle: .lingohub), "Nur in der App")
        let german = Bundle.lingohub

        sut.setLanguage("en")
        XCTAssertEqual(String(localized: "welcome", bundle: .lingohub), "Welcome (release)")
        XCTAssertFalse(Bundle.lingohub === german)

        // The override wins over the locale a lookup carries
        let resource = LocalizedStringResource("welcome", locale: Locale(identifier: "de"), bundle: .atURL(Bundle.lingohub.bundleURL))
        XCTAssertEqual(String(localized: resource), "Welcome (release)")
    }

    func testSystemLanguageServesAllLanguages() async throws {
        sut.configureForTests()
        try await installRelease()
        sut.setSystemLanguage()

        let bundle = Bundle.lingohub
        XCTAssertEqual(Set(bundle.localizations), ["en", "de", "fr"])
        XCTAssertEqual(bundle.developmentLocalization, "en")
        XCTAssertTrue(["Welcome (release)", "Willkommen (Release)"].contains(String(localized: "welcome", bundle: .lingohub)))

        // A LocalizedStringResource selects the localization from its locale
        func lookup(_ key: String.LocalizationValue, _ language: String) -> String {
            return String(localized: LocalizedStringResource(key, locale: Locale(identifier: language), bundle: .atURL(bundle.bundleURL)))
        }
        XCTAssertEqual(lookup("welcome", "en"), "Welcome (release)")
        XCTAssertEqual(lookup("welcome", "de"), "Willkommen (Release)")
        XCTAssertEqual(lookup("only_app", "de"), "Nur in der App")
    }

    func testReleaseOnlyLanguageFallsBackToTheDevelopmentLanguage() async throws {
        sut.configureForTests()
        try await installRelease()
        sut.setLanguage("fr")

        XCTAssertEqual(String(localized: "welcome", bundle: .lingohub), "Bienvenue (release)")
        XCTAssertEqual(String(localized: "only_app", bundle: .lingohub), "Only in the app")
    }

    func testOverrideWithoutAMatchingLanguageServesAllLanguages() async throws {
        sut.configureForTests()
        try await installRelease()
        sut.setLanguage("ja")

        XCTAssertEqual(Set(Bundle.lingohub.localizations), ["en", "de", "fr"])
    }

    func testPluralsResolveFromTheReleaseAndTheApp() async throws {
        sut.configureForTests()
        try await installRelease()

        sut.setLanguage("en")
        let english = Locale(identifier: "en")
        XCTAssertEqual(String(localized: "\(1) items", bundle: .lingohub, locale: english), "1 item (release)")
        XCTAssertEqual(String(localized: "\(5) items", bundle: .lingohub, locale: english), "5 items (release)")
        XCTAssertEqual(String(localized: "\(1) apples", bundle: .lingohub, locale: english), "1 apple (app)")

        sut.setLanguage("de")
        let german = Locale(identifier: "de")
        XCTAssertEqual(String(localized: "\(1) items", bundle: .lingohub, locale: german), "1 Ding (Release)")
        XCTAssertEqual(String(localized: "\(5) items", bundle: .lingohub, locale: german), "5 Dinge (Release)")
        XCTAssertEqual(String(localized: "\(3) apples", bundle: .lingohub, locale: german), "3 Äpfel (App)")
    }

    func testPluralCategoriesFollowTheLookupLocale() async throws {
        // Foundation selects the plural category from the formatting locale, so an
        // override whose plural rules differ from the device language (Russian on an
        // English device) passes the override's locale, as the README documents.
        let russianPlural: [String: Any] = [
            "NSStringLocalizedFormatKey": "%#@count@",
            "count": [
                "NSStringFormatSpecTypeKey": "NSStringPluralRuleType",
                "NSStringFormatValueTypeKey": "lld",
                "one": "%lld yabloko",
                "few": "%lld yabloka",
                "many": "%lld yablok",
                "other": "%lld yabloka-other",
            ] as [String: Any],
        ]
        let archive = auxDir.appendingPathComponent("ru.zip")
        try TestArchives.zip(files: TestArchives.releaseFiles(strings: [:], stringsdicts: ["ru": ["Localizable": ["%lld apples": russianPlural]]]), to: archive)
        sut.configureForTests()
        try await sut.installArchive(at: archive, identifier: "ru-release", appVersion: TestConstants.appVersion)
        sut.setLanguage("ru")

        let russian = Locale(identifier: "ru")
        XCTAssertEqual(String(localized: "\(1) apples", bundle: .lingohub, locale: russian), "1 yabloko")
        XCTAssertEqual(String(localized: "\(3) apples", bundle: .lingohub, locale: russian), "3 yabloka")
        XCTAssertEqual(String(localized: "\(5) apples", bundle: .lingohub, locale: russian), "5 yablok")
        XCTAssertEqual(String(localized: "\(21) apples", bundle: .lingohub, locale: russian), "21 yabloko")

        var resource = LocalizedStringResource("\(3) apples")
        resource.locale = russian
        XCTAssertEqual(String(lh: resource), "3 yabloka", "The resource's locale survives retargeting")

        #if canImport(SwiftUI)
        XCTAssertEqual(render(Text("\(5) apples", bundle: .lingohub).environment(\.locale, russian)), render(Text(verbatim: "5 yablok")))
        #endif
    }

    func testLocalizedStringResourceAtTheLingohubURL() async throws {
        sut.configureForTests()
        sut.setLanguage("en")
        try await installRelease()

        let resource = LocalizedStringResource("welcome", bundle: .atURL(Bundle.lingohub.bundleURL))

        XCTAssertEqual(String(localized: resource), "Welcome (release)")
    }

    func testAttributedStringParsesMarkdownFromTheRelease() async throws {
        sut.configureForTests()
        sut.setLanguage("en")
        try await installRelease()

        for attributed in [AttributedString(localized: "markdown", bundle: .lingohub), AttributedString(localized: sut.resolve("markdown"))] {
            XCTAssertEqual(String(attributed.characters), "Bold (release)")
            XCTAssertEqual(attributed.runs.count, 2, "The release's markdown must be parsed")
        }
    }

    // MARK: - resolve(_:), String(lh:)

    func testResolveServesTheReleaseKeepingKeyTableArgumentsAndLocale() async throws {
        sut.configureForTests()
        sut.setLanguage("en")
        try await installRelease()
        let name = "Ann"

        let greeting = sut.resolve(LocalizedStringResource("greeting", defaultValue: "Hello \(name)"))
        XCTAssertEqual(String(localized: greeting), "Hello Ann (release)")
        XCTAssertEqual(greeting.key, "greeting")

        let title = sut.resolve(LocalizedStringResource("title", table: "Settings"))
        XCTAssertEqual(String(localized: title), "Settings (app)")
        XCTAssertEqual(title.table, "Settings")

        let items = sut.resolve(LocalizedStringResource("\(5) items", locale: Locale(identifier: "en")))
        XCTAssertEqual(String(localized: items), "5 items (release)")

        let missing = sut.resolve(LocalizedStringResource("missing_everywhere", defaultValue: "Default \(7)"))
        XCTAssertEqual(String(localized: missing), "Default 7")

        XCTAssertEqual(sut.resolve(LocalizedStringResource("welcome", locale: .autoupdatingCurrent)).locale, .autoupdatingCurrent)
    }

    func testStringLH() async throws {
        sut.configureForTests()
        sut.setLanguage("de")
        try await installRelease()
        let name = "Ann"

        XCTAssertEqual(String(lh: "welcome"), "Willkommen (Release)")
        XCTAssertEqual(String(lh: LocalizedStringResource("greeting", defaultValue: "Hello \(name)")), "Hallo Ann (Release)")
        XCTAssertEqual(String(lh: "only_app"), "Nur in der App")
    }

    func testResolveLeavesResourcesUnchangedWithoutARelease() {
        sut.configureForTests()
        let resource = LocalizedStringResource("welcome")

        XCTAssertEqual(sut.resolve(resource), resource)
        XCTAssertEqual(String(lh: "missing_everywhere"), "missing_everywhere")
    }

    func testResolveLeavesOtherBundlesUnchanged() async throws {
        // Merged bundles mirror the app bundle only; a framework's or package's strings
        // must keep resolving in their own bundle.
        sut.configureForTests()
        try await installRelease()
        let packageResource = LocalizedStringResource("StringPlain", bundle: .atURL(Bundle.module.bundleURL))

        XCTAssertEqual(sut.resolve(packageResource), packageResource)
    }

    func testResolveRetargetsResourcesOfAnEarlierMergedBundle() async throws {
        sut.configureForTests()
        sut.setLanguage("en")
        try await installRelease("release-1")
        let stale = LocalizedStringResource("welcome", bundle: .atURL(Bundle.lingohub.bundleURL))

        try await installRelease("release-2", welcome: "Welcome (release 2)")

        XCTAssertEqual(String(localized: sut.resolve(stale)), "Welcome (release 2)")
    }

    // MARK: - SwiftUI

    #if canImport(SwiftUI)
    func testSwiftUITextRendersTheRelease() async throws {
        sut.configureForTests()
        sut.setLanguage("en")
        try await installRelease()

        let expected = render(Text(verbatim: "Welcome (release)"))
        XCTAssertNotEqual(render(Text("welcome", bundle: .main)), expected, "Control: the comparison must tell strings apart")
        XCTAssertEqual(render(Text("welcome", bundle: .lingohub)), expected)
        XCTAssertEqual(render(Text(lh: "welcome")), expected)
        XCTAssertEqual(render(Text(sut.resolve("welcome"))), expected)
        XCTAssertEqual(render(Text("only_app", bundle: .lingohub)), render(Text(verbatim: "Only in the app")))
        XCTAssertEqual(render(Text("\(5) items", bundle: .lingohub).environment(\.locale, Locale(identifier: "en"))), render(Text(verbatim: "5 items (release)")))
        XCTAssertEqual(render(Text(lh: "\(1) items").environment(\.locale, Locale(identifier: "en"))), render(Text(verbatim: "1 item (release)")))
    }

    /// `Text` resolves its string when it is rendered and exposes no public accessor for
    /// the result. Rendering it next to a verbatim `Text` of the expected string checks
    /// the resolved string through public API only.
    private func render<Content: View>(_ view: Content) -> Data {
        let renderer = ImageRenderer(content: view.font(.system(size: 17)).fixedSize())
        renderer.scale = 1
        guard let image = renderer.cgImage, let pixels = image.dataProvider?.data else {
            XCTFail("Rendering failed")
            return Data()
        }
        return Data(bytes: CFDataGetBytePtr(pixels), count: CFDataGetLength(pixels)) + Data("\(image.width)x\(image.height)".utf8)
    }
    #endif

    // MARK: - Activation

    func testNotificationObserversSeeTheNewRelease() async throws {
        sut.configureForTests()
        sut.setLanguage("en")
        try await installRelease("release-1")
        XCTAssertEqual(String(localized: "welcome", bundle: .lingohub), "Welcome (release)")

        let observed = CapturedValue<String>()
        // queue nil: the block runs synchronously on the posting thread
        let token = NotificationCenter.default.addObserver(forName: .LingoHubDidUpdateLocalization, object: nil, queue: nil) { _ in
            observed.value = String(localized: "welcome", bundle: .lingohub)
        }
        defer { NotificationCenter.default.removeObserver(token) }

        try await installRelease("release-2", welcome: "Welcome (release 2)")

        XCTAssertEqual(observed.value, "Welcome (release 2)")
    }

    func testLookupsAreConsistentWhileReleasesAreSwapped() throws {
        let store = LocalizationCacheManager.shared
        let source = MergedBundleSource(bundle: appBundle)
        var releases: [(url: URL, merged: MergedBundle)] = []
        for value in ["A", "B"] {
            let releaseURL = auxDir.appendingPathComponent("release\(value)")
            try TestArchives.write(files: TestArchives.releaseFiles(strings: ["en": ["Localizable": ["welcome": value]]]), to: releaseURL)
            let builder = MergedBundleBuilder(source: source, distributionVersion: value, folder: auxDir.appendingPathComponent("merged"))
            let merged = try builder.build(from: releaseURL)
            releases.append((releaseURL, merged))
        }
        store.language = "en"
        store.activate(bundleURL: releases[0].url, distributionVersion: "A", appVersion: "1", mergedBundle: releases[0].merged)

        DispatchQueue.concurrentPerform(iterations: 400) { i in
            if i % 40 == 0 {
                let release = releases[(i / 40) % 2]
                store.activate(bundleURL: release.url, distributionVersion: release.merged.manifest.distributionVersion, appVersion: "1", mergedBundle: release.merged)
            } else {
                let value = Bundle.lingohub.localizedString(forKey: "welcome", value: nil, table: nil)
                XCTAssertTrue(value == "A" || value == "B", "Unexpected value while releases are swapped: \(value)")
            }
        }

        store.deactivate()
    }

    func testDiscardedReleaseRestoresTheMainBundle() async throws {
        sut.configureForTests()
        try await installRelease()
        XCTAssertFalse(Bundle.lingohub === Bundle.main)

        // A new app version discards the release on the next launch
        sut.configure(withApiKey: TestConstants.apiKey, appVersion: TestConstants.updatedAppVersion)

        XCTAssertTrue(Bundle.lingohub === Bundle.main)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(sut.cacheManager.mergedBundlesFolderUrl).path))
    }

    // MARK: - Launch

    func testRelaunchReusesTheMergedBundleSynchronously() async throws {
        sut.configureForTests()
        sut.setLanguage("en")
        try await installRelease()
        await sut.waitForMergedBundleWork()
        let mergedURL = try XCTUnwrap(mergedBundleURL)

        // Simulate the next launch: served right away, nothing rebuilt
        sut.configureForTests()

        XCTAssertEqual(mergedBundleURL, mergedURL)
        XCTAssertEqual(String(localized: "welcome", bundle: .lingohub), "Welcome (release)")
    }

    func testRelaunchRebuildsWhenTheAppTablesChanged() async throws {
        sut.configureForTests()
        sut.setLanguage("en")
        try await installRelease()
        await sut.waitForMergedBundleWork()
        let outdatedURL = try XCTUnwrap(mergedBundleURL)

        // A new build of the app with the same version and a changed bundled string
        let table = try XCTUnwrap(appBundle.resourceURL).appendingPathComponent("en.lproj/Localizable.strings")
        let newBuild: [String: String] = ["welcome": "Welcome (app)", "only_app": "Only in the new build", "greeting": "Hello %@ (app)"]
        try PropertyListSerialization.data(fromPropertyList: newBuild, format: .binary, options: 0).write(to: table)

        let rebuilt = expectation(forNotification: .LingoHubDidUpdateLocalization, object: nil)
        sut.cacheManager.forgetMergedBundlesInUse() // a new process
        sut.configureForTests()
        XCTAssertTrue(Bundle.lingohub === Bundle.main, "An outdated merged bundle is never served")
        await fulfillment(of: [rebuilt], timeout: 10)

        XCTAssertNotEqual(mergedBundleURL, outdatedURL)
        XCTAssertEqual(String(localized: "only_app", bundle: .lingohub), "Only in the new build")
        XCTAssertEqual(String(localized: "welcome", bundle: .lingohub), "Welcome (release)")
        await sut.waitForMergedBundleWork()
        XCTAssertFalse(FileManager.default.fileExists(atPath: outdatedURL.path))
    }

    func testLaunchBuildsTheMergedBundleForAReleaseInstalledByAnEarlierSDK() async throws {
        sut.configureForTests()
        sut.setLanguage("en")
        try await installRelease()
        await sut.waitForMergedBundleWork()
        // SDK 2.0 installed releases without a merged bundle
        try FileManager.default.removeItem(at: try XCTUnwrap(sut.cacheManager.mergedBundlesFolderUrl))

        let built = expectation(forNotification: .LingoHubDidUpdateLocalization, object: nil)
        sut.configureForTests()
        await fulfillment(of: [built], timeout: 10)

        XCTAssertEqual(String(localized: "welcome", bundle: .lingohub), "Welcome (release)")
    }

    func testMergedBundlesHandedOutStayUntilTheNextLaunch() async throws {
        sut.configureForTests()
        try await installRelease("release-1")
        let first = try XCTUnwrap(mergedBundleURL)
        try await installRelease("release-2")
        let second = try XCTUnwrap(mergedBundleURL)
        try await installRelease("release-3")
        let third = try XCTUnwrap(mergedBundleURL)
        await sut.waitForMergedBundleWork()

        // Views and resources may still resolve against any of them
        let all: Set<String> = [first.lastPathComponent, second.lastPathComponent, third.lastPathComponent]
        XCTAssertEqual(try mergedFolderContents(), all)

        // Configuring again in the same process keeps them
        sut.configureForTests()
        await sut.waitForMergedBundleWork()
        XCTAssertEqual(try mergedFolderContents(), all)

        // The next launch removes the superseded ones
        sut.cacheManager.forgetMergedBundlesInUse()
        sut.configureForTests()
        await sut.waitForMergedBundleWork()
        XCTAssertEqual(try mergedFolderContents(), [third.lastPathComponent])
    }

    func testStoredResourceOfAnEarlierReleaseStillResolves() async throws {
        // Foundation loads tables lazily: a resource created while release 1 was active,
        // looking up a table nothing has loaded yet, must still resolve after two more
        // releases replaced its merged bundle
        sut.configureForTests()
        sut.setLanguage("en")
        try await installRelease("release-1")
        let stored = LocalizedStringResource("title", table: "Settings", locale: Locale(identifier: "en"), bundle: .atURL(Bundle.lingohub.bundleURL))

        try await installRelease("release-2")
        try await installRelease("release-3")
        await sut.waitForMergedBundleWork()

        XCTAssertEqual(String(localized: stored), "Settings (app)")
    }

    func testReleaseStaysActiveWhenItsMergedBundleCannotBeBuilt() async throws {
        let table = try XCTUnwrap(appBundle.resourceURL).appendingPathComponent("en.lproj/Localizable.strings")
        try Data("{{{{ not a strings file".utf8).write(to: table)
        sut.configureForTests()
        sut.setLanguage("en")

        try await installRelease()

        XCTAssertTrue(sut.isUpdatedBundleUsed)
        XCTAssertTrue(Bundle.lingohub === Bundle.main, "Without a merged bundle, Swift lookups keep the bundled strings")
        XCTAssertEqual(sut.localizedString(forKey: "welcome"), "Welcome (release)", "Swizzled and manual lookups are unaffected")
    }
}

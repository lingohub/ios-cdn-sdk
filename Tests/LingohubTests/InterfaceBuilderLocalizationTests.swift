//
//  InterfaceBuilderLocalizationTests.swift
//
//  Storyboards and XIBs localized with Base Internationalization look up their
//  `.strings` tables through `Bundle.localizedString(forKey:value:table:)`, the method
//  swizzling intercepts, so they show downloaded translations like `NSLocalizedString`.
//
//  Fixtures: `Resources/InterfaceBuilder/Greeting.xib` and `Main.storyboard`, compiled
//  into `Resources/InterfaceBuilder/Compiled` from a `Base.lproj` folder (only there
//  does ibtool embed the `<object ID>.text` localization keys):
//
//      xcrun ibtool --compile Compiled/Greeting.nib Base.lproj/Greeting.xib --target-device iphone --minimum-deployment-target 15.0
//      xcrun ibtool --compile Compiled/Main.storyboardc Base.lproj/Main.storyboard --target-device iphone --minimum-deployment-target 15.0
//

#if canImport(UIKit)
import UIKit
import XCTest
@testable import Lingohub

@MainActor
final class InterfaceBuilderLocalizationTests: XCTestCase {
    let sut: LingoHubSDK = LingoHubSDK.testInstance()

    private var testStorageRoot: URL!
    /// Stands in for the app bundle: the compiled XIB and storyboard in Base.lproj,
    /// with their bundled translations in en.lproj and de.lproj.
    private var hostBundle: Bundle!

    @MainActor
    override func setUp() async throws {
        try await super.setUp()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LingohubInterfaceBuilderTests-\(UUID().uuidString)")
        testStorageRoot = root
        sut.cacheManager.storageRootOverride = root.appendingPathComponent("current")
        sut.cacheManager.legacyStorageRootOverride = root.appendingPathComponent("legacy")
        sut.reset()

        let hostURL = root.appendingPathComponent("Host.bundle")
        let compiled = try XCTUnwrap(Bundle.module.url(forResource: "Compiled", withExtension: nil))
        try FileManager.default.createDirectory(at: hostURL.appendingPathComponent("Base.lproj"), withIntermediateDirectories: true)
        for name in ["Greeting.nib", "Main.storyboardc"] {
            try FileManager.default.copyItem(at: compiled.appendingPathComponent(name), to: hostURL.appendingPathComponent("Base.lproj/\(name)"))
        }
        var tables: [String: Data] = [:]
        for language in ["en", "de"] {
            tables["\(language).lproj/Greeting.strings"] = Data(#""gre-et-ing.text" = "Greeting (bundled)";"#.utf8)
            tables["\(language).lproj/Main.strings"] = Data(#""sto-ry-lbl.text" = "Title (bundled)";"#.utf8)
        }
        try TestArchives.write(files: tables, to: hostURL)
        hostBundle = try XCTUnwrap(Bundle(url: hostURL))
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

    private func installRelease() async throws {
        let archive = testStorageRoot.appendingPathComponent("release.zip")
        var strings: [String: [String: [String: String]]] = [:]
        for language in ["en", "de"] {
            strings[language] = [
                "Greeting": ["gre-et-ing.text": "Greeting (release)"],
                "Main": ["sto-ry-lbl.text": "Title (release)"],
            ]
        }
        try TestArchives.zip(files: TestArchives.releaseFiles(strings: strings), to: archive)
        try await sut.installArchive(at: archive, identifier: "interface-builder", appVersion: TestConstants.appVersion)
    }

    private func xibLabelText() -> String? {
        let objects = UINib(nibName: "Greeting", bundle: hostBundle).instantiate(withOwner: nil, options: nil)
        return (objects.first as? UILabel)?.text
    }

    private func storyboardLabelText() -> String? {
        let viewController = UIStoryboard(name: "Main", bundle: hostBundle).instantiateInitialViewController()
        return (viewController?.view.subviews.first as? UILabel)?.text
    }

    func testXIBShowsTheRelease() async throws {
        sut.configureForTests()
        sut.setLanguage("en")
        XCTAssertEqual(xibLabelText(), "Greeting (bundled)")

        try await installRelease()
        sut.swizzleBundle(hostBundle)

        XCTAssertEqual(xibLabelText(), "Greeting (release)")
    }

    func testStoryboardShowsTheRelease() async throws {
        sut.configureForTests()
        sut.setLanguage("en")
        XCTAssertEqual(storyboardLabelText(), "Title (bundled)")

        try await installRelease()
        sut.swizzleBundle(hostBundle)

        XCTAssertEqual(storyboardLabelText(), "Title (release)")
    }
}
#endif

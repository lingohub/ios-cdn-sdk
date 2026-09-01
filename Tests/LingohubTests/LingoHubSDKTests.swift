//
//  LingohubSDKTests.swift
//
//  Created by Manfred Baldauf on 12.03.24.
//

import XCTest
@testable import Lingohub
import Mocker

@MainActor
final class LingohubSDKTests: XCTestCase {
    let sut: LingohubSDK = LingohubSDK.testInstance()

    @MainActor
    override func setUp() async throws {
        try await super.setUp()
        // Start from a clean slate even if a previous (crashed) run left persisted state
        sut.reset()
    }

    /// Expected value of the update bundle's "StringPlain" for the host's system
    /// language, or nil when the host runs a language the fixtures don't cover.
    private var systemLanguageStringPlain: String? {
        switch Locale.lingohubLanguageCode {
        case "en": return "String"
        case "de": return "Text"
        default: return nil
        }
    }

    @MainActor
    override func tearDown() async throws {
        sut.reset()
        Bundle.deswizzle()

        try await super.tearDown()

        // Verify reset state
        XCTAssertNil(sut.apiKey)
        XCTAssertNil(sut.appVersion)
        XCTAssertNil(sut.language)
        XCTAssertNil(sut.updateAppVersion)
        XCTAssertNil(sut.distributionVersion)
        XCTAssertFalse(sut.updateBundleExists)
        XCTAssertEqual(sut.environment, .production)
        XCTAssertEqual(sut.swizzledBundles, [])
    }

    func testConfiguration() async throws {
        // Given
        XCTAssertNil(sut.apiKey)
        XCTAssertNil(sut.appVersion)

        // When
        sut.configure(withApiKey: TestConstants.apiKey, appVersion: TestConstants.appVersion)

        // Then
        XCTAssertEqual(sut.apiKey, TestConstants.apiKey)
        XCTAssertEqual(sut.appVersion, TestConstants.appVersion)
    }


    func testParsing() async throws {
        // Given
        guard let url = Bundle.module.url(forResource: "update_200", withExtension: "json"),
              let data = try? Data(contentsOf: url)else {
            XCTFail()
            return
        }

        // When
        let endpoint = Endpoint<BundleInfo>(method: .get, path: "", parameters: [:], headers: [:]) { data in
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom { decoder in
                let container = try decoder.singleValueContainer()
                let timestamp = try container.decode(Int64.self)
                return Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000.0)
            }
            return try decoder.decode(BundleInfo.self, from: data)
        }

        // Then
        do {
            let bundleInfo = try endpoint.decode(data)
            XCTAssertEqual(bundleInfo.id, "test-bundle-id")
            XCTAssertEqual(bundleInfo.name, "Test Bundle")
            if #available(iOS 14.0, *) {
                XCTAssertEqual(bundleInfo.filesUrl, URL(string: "https://s3.amazon.de/update.zip"))
            } else {
                // Fallback on earlier versions
            }

            let iso8601Formatter = ISO8601DateFormatter()
            iso8601Formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let date = iso8601Formatter.date(from: "2025-03-13T13:55:22.028+00:00")

            XCTAssertEqual(bundleInfo.createdAt, date)
        } catch {
            XCTFail()
        }
    }


    func testSdkVersion() async throws {
        // Given/When
        sut.configureForTests()

        // Then
        XCTAssertEqual(sut.sdkVersion, LingohubConstants.version)
    }

    func testLanguageOverride() async throws {
        // Given
        XCTAssertNil(sut.language)

        // When
        sut.setLanguage("de")

        // Then
        XCTAssertEqual(sut.language, "de")
    }

    func testSystemLanguage() async throws {
        // Given
        sut.setLanguage("de")
        XCTAssertEqual(sut.language, "de")

        // When
        sut.setSystemLanguage()

        // Then
        XCTAssertNil(sut.language)
    }

    func testEnvironmentMode() async throws {
        // Given
        XCTAssertEqual(sut.environment, .production)

        // When
        sut.environment = .test

        // Then
        XCTAssertEqual(sut.environment, .test)

        // When
        sut.environment = .production

        // Then
        XCTAssertEqual(sut.environment, .production)
    }

    func testBundleSwizzling() async throws {
        // Given
        let bundle = Bundle(for: type(of: self))
        let bundlePath = bundle.bundlePath
        XCTAssertEqual(sut.swizzledBundles, [])

        // When
        sut.swizzleBundle(bundle)

        // Then
        XCTAssertEqual(sut.swizzledBundles, [bundlePath])

        // When swizzling the same bundle again
        sut.swizzleBundle(bundle)

        // Then it should still only appear once
        XCTAssertEqual(sut.swizzledBundles, [bundlePath])
    }

    func testSwizzlingSecondBundleKeepsFirst() async throws {
        // Given
        let firstBundle = Bundle(for: type(of: self))
        let secondBundle = Bundle.module
        XCTAssertNotEqual(firstBundle.bundlePath, secondBundle.bundlePath)

        // When
        sut.swizzleBundle(firstBundle)
        sut.swizzleBundle(secondBundle)

        // Then both bundles stay registered
        XCTAssertEqual(Set(sut.swizzledBundles), Set([firstBundle.bundlePath, secondBundle.bundlePath]))
    }

    func testUpdate() async throws {
        sut.configureForTests()

        MockService.mockUpdate200()
        MockService.mockBundleDownload200()

        let expectation = XCTestExpectation()

        sut.update { result in
            switch result {
            case .success(let value):
                XCTAssertTrue(value)
            case .failure:
                XCTFail()
            }

            expectation.fulfill()
        }

        await fulfillment(of: [expectation], timeout: 3.0)

        XCTAssertEqual(sut.updateAppVersion, TestConstants.appVersion)
        XCTAssertEqual(sut.distributionVersion, TestConstants.bundleIdentifier)
    }

    func testUpdateNoContent() async throws {
        sut.configureForTests()

        MockService.mockUpdate204()

        let expectation = XCTestExpectation()

        sut.update { result in
            switch result {
            case .success(let value):
                XCTAssertFalse(value)
            case .failure:
                XCTFail()
            }

            expectation.fulfill()
        }

        await fulfillment(of: [expectation], timeout: 3.0)
    }


    func testUpdateError() async throws {
        sut.configureForTests()

        MockService.mockUpdate401()

        let expectation = XCTestExpectation()

        sut.update { result in
            switch result {
            case .success:
                XCTFail()
            case .failure(let error):
                switch error {
                case LingohubSDKError.apiError(let statusCode, let message):
                    XCTAssertEqual(statusCode, 401)
                    XCTAssertEqual(message, "Unauthorized (CDN_KEY_NOT_FOUND)")
                default:
                    XCTFail()
                }
            }

            expectation.fulfill()
        }

        await fulfillment(of: [expectation], timeout: 3.0)
    }

    func testUpdateErrorLegacyFormat() async throws {
        sut.configureForTests()

        MockService.mockUpdate401Legacy()

        let expectation = XCTestExpectation()

        sut.update { result in
            switch result {
            case .success:
                XCTFail()
            case .failure(let error):
                switch error {
                case LingohubSDKError.apiError(let statusCode, let message):
                    XCTAssertEqual(statusCode, 401)
                    XCTAssertEqual(message, "Unauthorized access")
                default:
                    XCTFail()
                }
            }

            expectation.fulfill()
        }

        await fulfillment(of: [expectation], timeout: 3.0)
    }

    func testUpdate404WithoutInfoRemainsError() async throws {
        // Only the CDN's DISTRIBUTION_NOT_FOUND problem is normalized to "no update".
        // A 404 without that structured body (wrong route, proxy misconfiguration)
        // must stay a failure.
        sut.configureForTests()

        MockService.mockUpdate404WithoutInfo()

        let expectation = XCTestExpectation()

        sut.update { result in
            switch result {
            case .success:
                XCTFail()
            case .failure(let error):
                switch error {
                case LingohubSDKError.apiError(let statusCode, _):
                    XCTAssertEqual(statusCode, 404)
                default:
                    XCTFail()
                }
            }

            expectation.fulfill()
        }

        await fulfillment(of: [expectation], timeout: 3.0)
    }

    func testUpdateNoReleasePublished() async throws {
        // A 404 with the CDN's DISTRIBUTION_NOT_FOUND problem means no release matches
        // the app version and no fallback exists. That is a normal state
        // (e.g. nothing published yet), not an error.
        sut.configureForTests()

        MockService.mockUpdate404()

        let expectation = XCTestExpectation()

        sut.update { result in
            switch result {
            case .success(let value):
                XCTAssertFalse(value)
            case .failure:
                XCTFail()
            }

            expectation.fulfill()
        }

        await fulfillment(of: [expectation], timeout: 3.0)
    }

    func testUpdateDownloadError() async throws {
        sut.configureForTests()

        MockService.mockUpdate200()
        MockService.mockBundleDownload404()

        let expectation = XCTestExpectation()

        sut.update { result in
            switch result {
            case .success:
                XCTFail()
            case .failure(let error):
                switch error {
                case LingohubSDKError.apiError(let statusCode, let message):
                    XCTAssertEqual(statusCode, 404)
                    XCTAssertNil(message)
                default:
                    XCTFail()
                }
            }

            expectation.fulfill()
        }

        await fulfillment(of: [expectation], timeout: 3.0)
    }

    func testBundleUpdate() async throws {
        // Given
        sut.configureForTests()
        XCTAssertNil(sut.distributionVersion)

        // When/Then
        do {
            try sut.useUpdatedBundle(atURL: TestConstants.updateBundleURL, withIdentifier: LingohubConstants.distributionVersion, appVersion: TestConstants.appVersion)
            XCTAssertEqual(sut.distributionVersion, LingohubConstants.distributionVersion)
        } catch {
            XCTFail()
        }
    }

    func testNotification() async throws {
        // Given
        sut.configureForTests()
        MockService.mockUpdate200()
        MockService.mockBundleDownload200()

        // Create expectation for notification
        let expectation = expectation(forNotification: .LingohubDidUpdateLocalization, object: nil, handler: nil)

        // When
        sut.update()

        // Then
        await fulfillment(of: [expectation], timeout: 3.0)

        XCTAssertEqual(sut.updateAppVersion, TestConstants.appVersion)
        XCTAssertEqual(sut.distributionVersion, TestConstants.bundleIdentifier)
    }

    func testLocalization() async throws {
        // Given
        sut.configureForTests()
        sut.setLanguage("en") // independent of the host's system language

        // When
        let stringBefore = sut.localizedString(forKey: "StringPlain")

        // Then
        XCTAssertNil(stringBefore)

        // When
        sut.installUpdatedBundle()
        sut.swizzleBundle(Bundle.module)
        let stringAfter = sut.localizedString(forKey: "StringPlain")

        // Then
        XCTAssertEqual(stringAfter, "String")
    }

    func testSwizzle() async throws {
        sut.configureForTests()
        sut.setLanguage("en") // independent of the host's system language
        XCTAssertEqual(sut.swizzledBundles.count, 0)

        sut.installUpdatedBundle()

        // Unswizzled lookups resolve via the system mechanism, so the expected value
        // depends on which localization the test bundle picks for this host.
        let stringBefore = NSLocalizedString("StringPlain", tableName: nil, bundle: Bundle.module, value: "", comment: "")
        switch Bundle.module.preferredLocalizations.first {
        case "en": XCTAssertEqual(stringBefore, "String from test bundle")
        case "de": XCTAssertEqual(stringBefore, "Text aus dem Test Bundle")
        default: break
        }

        // Don't swizzle Bundle.module, test sut.localizedString directly
        sut.swizzleBundle(Bundle.module)
        XCTAssertEqual(sut.swizzledBundles.count, 1)
        XCTAssertEqual(sut.swizzledBundles, [Bundle.module.bundlePath])

        let stringAfter = sut.localizedString(forKey: "StringPlain")
        XCTAssertEqual(stringAfter, "String")
    }

    func testAddedString() async throws {
        sut.configureForTests()
        sut.setLanguage("en") // independent of the host's system language
        sut.installUpdatedBundle()

        let stringBefore = String.localized("OtherString", tableName: "Other")

        XCTAssertEqual(stringBefore, "OtherString")
        sut.swizzleBundle(Bundle.module)

        let stringAfter = NSLocalizedString("OtherString", tableName: "Other", bundle: Bundle.module, value: "", comment: "")
        XCTAssertEqual(stringAfter, "Other string")
    }

    func testFiles() async throws {
        // Given
        sut.configureForTests()
        sut.setLanguage("en") // independent of the host's system language
        sut.installUpdatedBundle()
        // Remove swizzling of Bundle.module
        // sut.swizzleBundle(Bundle.module)

        // When: Use SDK's direct lookup for strings expected from update bundle
        let otherString = sut.localizedString(forKey: "OtherString", tableName: "Localizable")
        let otherStringFromOtherTable = sut.localizedString(forKey: "OtherString", tableName: "Other")

        // Then
        XCTAssertNotEqual(otherString, otherStringFromOtherTable)
        XCTAssertEqual(otherString, "String") // Expect 'String' from updateBundle's Localizable.strings
        XCTAssertEqual(otherStringFromOtherTable, "Other string") // Expect 'Other string' from updateBundle's Other.strings
    }

    func testLanguage() async throws {
        // Given
        sut.configureForTests()
        sut.installUpdatedBundle()
        sut.swizzleBundle(Bundle.module)

        // Debug bundle resources
        Bundle.debugBundleResources()

        // When/Then: without an override, the system language decides
        if let expected = systemLanguageStringPlain {
            XCTAssertEqual(expected, sut.localizedString(forKey: "StringPlain"))
        }
        // When/Then
        sut.setLanguage("de")
        let stringDe = sut.localizedString(forKey: "StringPlain")
        XCTAssertEqual("Text", stringDe)

        // When/Then
        sut.setLanguage("en")
        let stringEnAgain = sut.localizedString(forKey: "StringPlain")
        XCTAssertEqual("String", stringEnAgain)

        // When/Then
        sut.setLanguage("de")
        let stringDeAgain = sut.localizedString(forKey: "StringPlain")
        XCTAssertEqual("Text", stringDeAgain)

        // When/Then: back to the system language
        sut.setSystemLanguage()
        if let expected = systemLanguageStringPlain {
            XCTAssertEqual(expected, sut.localizedString(forKey: "StringPlain"))
        }
    }
}

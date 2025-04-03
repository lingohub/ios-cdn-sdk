//
//  LingohubSDK+Testing.swift
//
//  Created by Manfred Baldauf on 12.03.24.
//

import Foundation
@testable import Lingohub
import Mocker

public extension LingohubSDK {
    static func testInstance() -> LingohubSDK {
        let lingohub = LingohubSDK.shared
        let configuration = URLSessionConfiguration.default
        configuration.protocolClasses = [MockingURLProtocol.self]
        lingohub.apiClient = APIClient(basePath: LingohubConstants.basePath, configuration: configuration)
        return lingohub
    }

    func configureForTests() {
        configure(withApiKey: TestConstants.apiKey, appVersion: TestConstants.appVersion)
    }

   func installUpdatedBundle() {
        do {
            try useUpdatedBundle(atURL: TestConstants.updateBundleURL, withIdentifier: TestConstants.bundleIdentifier, appVersion: TestConstants.appVersion)
        } catch {
            print("[Lingohub] \(error)")

        }
    }

    func reset() {
        apiKey = nil
        appVersion = nil
        setSystemLanguage()
        environment = .production
        swizzledBundles = []
        cleanUp()
    }
}

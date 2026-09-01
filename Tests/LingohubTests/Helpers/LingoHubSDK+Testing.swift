//
//  LingoHubSDK+Testing.swift
//
//  Created by Manfred Baldauf on 12.03.24.
//

import Foundation
@testable import Lingohub
import Mocker

public extension LingoHubSDK {
    static func testInstance() -> LingoHubSDK {
        let lingohub = LingoHubSDK.shared
        let configuration = URLSessionConfiguration.default
        configuration.protocolClasses = [MockingURLProtocol.self]
        lingohub.apiClient = APIClient(basePath: LingoHubConstants.basePath, configuration: configuration)
        return lingohub
    }

    func configureForTests() {
        configure(withApiKey: TestConstants.apiKey, appVersion: TestConstants.appVersion)
    }

    func installUpdatedBundle() async {
        do {
            try await installArchive(at: TestConstants.updateBundleURL, identifier: TestConstants.bundleIdentifier, appVersion: TestConstants.appVersion)
        } catch {
            print("[LingoHub] \(error)")
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

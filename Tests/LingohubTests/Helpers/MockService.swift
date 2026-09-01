//
//  MockService.swift
//
//  Created by Manfred Baldauf on 12.03.24.
//

import Foundation
@testable import Lingohub
import Mocker

/// A service for mocking network responses
public final class MockService {
    private static let updateUrl = URL(string: LingoHubConstants.basePath + "v1/distributions/check")!
    private static let downloadUrl = URL(string: "https://s3.amazon.de/update.zip")!

    private static func loadResource(_ name: String, withExtension fileExtension: String) -> Data {
        print("🔍 [MockService] Attempting to load resource: \(name).\(fileExtension)")
        print("🔍 [MockService] Using test bundle path: \(Bundle.module.bundlePath)")

        guard let url = Bundle.module.url(forResource: name, withExtension: fileExtension) else {
            print("🔍 [MockService] ⚠️ Could not find URL for resource: \(name).\(fileExtension)")
            fatalError("could not load resource \(name).\(fileExtension) in Test-Bundle")
        }

        print("🔍 [MockService] Found resource at: \(url.path)")

        guard let data = try? Data(contentsOf: url) else {
            print("🔍 [MockService] ⚠️ Could not load data from URL: \(url.path)")
            fatalError("could not load resource \(name).\(fileExtension) in Test-Bundle")
        }

        print("🔍 [MockService] Successfully loaded \(data.count) bytes of data")
        return data
    }
}

extension MockService {
    @objc public static func mockBundleDownload200() {
        print("🔍 [MockService] Setting up mock for bundle download 200")
        let data = loadResource("update", withExtension: "zip")

        let mock = Mock(url: downloadUrl, contentType: .zip, statusCode: 200, data: [
            .get: data
        ])
        mock.register()
        print("🔍 [MockService] Registered mock for bundle download")
    }

    @objc public static func mockBundleDownload404() {
        print("🔍 [MockService] Setting up mock for bundle download 404")
        let data = loadResource("empty", withExtension: "json")
        let mock = Mock(url: downloadUrl, contentType: .json, statusCode: 404, data: [
            .get: data
        ])
        mock.register()
        print("🔍 [MockService] Registered mock for bundle download 404")
    }
}

extension MockService {
    @objc public static func mockUpdate200() {
        let data = loadResource("update_200", withExtension: "json")
        let mock = Mock(url: updateUrl, ignoreQuery: true, contentType: .json, statusCode: 200, data: [
            .post: data
        ])
        mock.register()
    }

    @objc public static func mockUpdate204() {
        let data = loadResource("empty", withExtension: "json")
        let mock = Mock(url: updateUrl, ignoreQuery: true, contentType: .json, statusCode: 204, data: [
            .post: data
        ])
        mock.register()
    }

    @objc public static func mockUpdate401() {
        let data = loadResource("update_401", withExtension: "json")
        let mock = Mock(url: updateUrl, ignoreQuery: true, contentType: .json, statusCode: 401, data: [
            .post: data
        ])
        mock.register()
    }

    @objc public static func mockUpdate401Legacy() {
        let data = loadResource("update_401_legacy", withExtension: "json")
        let mock = Mock(url: updateUrl, ignoreQuery: true, contentType: .json, statusCode: 401, data: [
            .post: data
        ])
        mock.register()
    }

    @objc public static func mockUpdate404() {
        let data = loadResource("update_404", withExtension: "json")
        let mock = Mock(url: updateUrl, ignoreQuery: true, contentType: .json, statusCode: 404, data: [
            .post: data
        ])
        mock.register()
    }

    /// A 404 without the CDN's DISTRIBUTION_NOT_FOUND problem body, e.g. from a
    /// misconfigured proxy or wrong route.
    @objc public static func mockUpdate404WithoutInfo() {
        let data = loadResource("empty", withExtension: "json")
        let mock = Mock(url: updateUrl, ignoreQuery: true, contentType: .json, statusCode: 404, data: [
            .post: data
        ])
        mock.register()
    }

    /// A transport failure before any response is received (e.g. offline).
    @objc public static func mockUpdateNetworkError() {
        let mock = Mock(url: updateUrl, ignoreQuery: true, contentType: .json, statusCode: 200, data: [
            .post: Data()
        ], requestError: URLError(.notConnectedToInternet))
        mock.register()
    }

    @objc public static func mockUpdate429() {
        let data = loadResource("update_429", withExtension: "json")
        let mock = Mock(url: updateUrl, ignoreQuery: true, contentType: .json, statusCode: 429, data: [
            .post: data
        ])
        mock.register()
    }
}

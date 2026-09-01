//
//  UpdateEndpoint.swift
//
//
//  Created by Manfred Baldauf on 12.03.25.
//

import Foundation

extension APIClient {
    func checkForUpdates(apiKey: String, appVersion: String, sdkVersion: String, distributionVersion: String?, environment: Environment, deviceIdentifier: String?, languageCode: String?) async throws -> BundleInfo {

        // Parameters according to https://developers.lingohub.com/reference/cdncheck
        var parameters: [String: Any] = [
            "distributionType": "MOBILE_SDK_IOS",
            "distributionEnvironment": environment.rawValue,
            "clientVersion": appVersion,
            "clientUser": deviceIdentifier ?? UUID().uuidString,
            "clientAgent": "LingoHub-iOS-SDK/\(sdkVersion)"
        ]

        if let distributionVersion = distributionVersion {
            parameters["clientRelease"] = distributionVersion
        }

        if let languageCode = languageCode {
            parameters["clientLanguageCode"] = languageCode
        }

        // Set up headers with content-type, accept, and bearer token
        let headers: [String: String] = [
            "Content-Type": "application/json",
            "Accept": "application/json",
            "Authorization": "Bearer \(apiKey)"
        ]

        let endpoint = Endpoint<BundleInfo>(method: .post, path: "v1/distributions/check", parameters: parameters, headers: headers)
        return try await send(endpoint: endpoint)
    }
}

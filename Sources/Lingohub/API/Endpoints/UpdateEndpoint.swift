//
//  UpdateEndpoint.swift
//
//
//  Created by Manfred Baldauf on 12.03.25.
//

import Foundation

extension APIClient {
    func checkForUpdates(apiKey: String, appVersion: String, sdkVersion: String, distributionVersion: String?, environment: Environment, deviceIdentifier: String?, languageCode: String?, completion: @escaping (() throws -> BundleInfo) -> Void) {

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

        LingoHubLogger.shared.log("API request parameters: \(parameters)")

        // Set up headers with content-type, accept, and bearer token
        let headers: [String: String] = [
            "Content-Type": "application/json",
            "Accept": "application/json",
            "Authorization": "Bearer \(apiKey)"
        ]

        let path = "v1/distributions/check"
        LingoHubLogger.shared.log("API request path: \(path)")

        let endpoint = Endpoint<BundleInfo>(method: .post, path: path, parameters: parameters, headers: headers)
        LingoHubLogger.shared.log("Sending API request")

        request(endpoint: endpoint) { response in
            LingoHubLogger.shared.log("Received API response")
            do {
                let bundleInfo = try response()
                LingoHubLogger.shared.log("Successfully parsed BundleInfo: id=\(bundleInfo.id), name=\(bundleInfo.name), filesUrl=\(bundleInfo.filesUrl.absoluteString)")
                completion { return bundleInfo }
            } catch {
                LingoHubLogger.shared.log("Error in API response: \(error)")
                completion { throw error }
            }
        }
    }
}

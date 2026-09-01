//
//  APIClientProtocol.swift
//
//
//  Created by Manfred Baldauf on 12.03.25.
//

import Foundation

/// The network operations the SDK needs for an update cycle. `APIClient` is the
/// production conformance; tests inject their own to observe or fake traffic.
protocol APIClientProtocol: Sendable {
    /// Asks the CDN whether a newer release exists for this app.
    /// Throws `APIError.noContent` when the CDN reports nothing new (204).
    func checkForUpdates(
        apiKey: String,
        appVersion: String,
        sdkVersion: String,
        distributionVersion: String?,
        environment: Environment,
        deviceIdentifier: String?,
        languageCode: String?
    ) async throws -> BundleInfo

    /// Downloads the release archive and returns the local file URL of the
    /// downloaded ZIP. The caller is responsible for deleting the file.
    func download(from url: URL) async throws -> URL
}

enum APIError: Error {
    case noContent
    case invalidURL
    case invalidResponse
    /// `infos` carries the structured RFC 7807 error codes (e.g. DISTRIBUTION_NOT_FOUND)
    /// from the CDN's problem-details body, empty when the body had none.
    case apiError(statusCode: Int, message: String?, infos: [String])
}

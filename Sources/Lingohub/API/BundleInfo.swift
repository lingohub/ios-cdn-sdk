//
//  ExportRequest.swift
//
//  Created by Manfred Baldauf on 12.03.24.
//

import Foundation

/// Environment for the bundle
public enum Environment: String, Codable, Sendable {
    case test = "TEST"
    case staging = "STAGING"
    case development = "DEVELOPMENT"
    case production = "PRODUCTION"
}

/// Release metadata returned by the CDN's check endpoint.
///
/// Decoding is strict: a 200 response without a usable `filesUrl` is a malformed
/// response and surfaces as a `DecodingError` instead of being silently patched over.
struct BundleInfo: Decodable, Sendable {
    /// The identifier of the distribution release
    let id: String
    /// The name of the bundle
    let name: String
    /// The URL to download the release archive from
    let filesUrl: URL
    /// SHA-256 hex digest of the release archive. Optional: older CDN versions
    /// don't send it; when present, the download is verified against it.
    let filesSha256: String?

    private enum CodingKeys: String, CodingKey {
        case id = "distributionReleaseId"
        case name
        case filesUrl
        case filesSha256
    }
}

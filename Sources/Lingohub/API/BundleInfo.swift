//
//  ExportRequest.swift
//
//  Created by Manfred Baldauf on 12.03.24.
//

import Foundation

/// Environment for the bundle
public enum Environment: String, Codable {
    case test = "TEST"
    case staging = "STAGING"
    case development = "DEVELOPMENT"
    case production = "PRODUCTION"
}

/// Export request response model
public struct BundleInfo: Codable {
    /// The identifier of the export request
    public let id : String
    /// The URL to download the exported resources (only available when status is completed)
    public let filesUrl: URL?
    /// The date when the export request was created
    public let createdAt: Date
    /// The name of the bundle
    public let name: String

    private enum CodingKeys: String, CodingKey {
        case id = "distributionReleaseId"
        case name
        case filesUrl
        case createdAt
    }

    public  init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Required fields
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        filesUrl = try container.decode(URL.self, forKey: .filesUrl)

        // Handle createdAt as ISO8601 string with timezone offset: "2025-03-13T13:55:22.028+00:00"
        if let dateString = try? container.decode(String.self, forKey: .createdAt) {
            let iso8601Formatter = ISO8601DateFormatter()
            iso8601Formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            if let date = iso8601Formatter.date(from: dateString) {
                createdAt = date
            } else {
                LingohubLogger.shared.log("Could not parse date string: \(dateString)")
                createdAt = Date() // Fallback to current date
            }
        } else {
            // Fallback to current date if parsing fails
            LingohubLogger.shared.log("Could not decode createdAt field as string")
            createdAt = Date()
        }
    }
}

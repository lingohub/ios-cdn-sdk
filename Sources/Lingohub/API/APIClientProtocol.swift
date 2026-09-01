//
//  APIClientProtocol.swift
//
//
//  Created by Manfred Baldauf on 12.03.25.
//

import Foundation

enum APIError: Error {
    case noContent
    case invalidURL
    case invalidResponse
    /// `infos` carries the structured RFC 7807 error codes (e.g. DISTRIBUTION_NOT_FOUND)
    /// from the CDN's problem-details body, empty when the body had none.
    case apiError(statusCode: Int, message: String?, infos: [String])
}

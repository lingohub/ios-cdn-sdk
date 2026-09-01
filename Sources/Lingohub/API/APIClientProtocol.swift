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
    case apiError(statusCode: Int, message: String?)
}

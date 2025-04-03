//
//  APIClientProtocol.swift
//
//
//  Created by Manfred Baldauf on 12.03.25.
//

import Foundation

/// Protocol for API clients
protocol APIClientProtocol {
    /// Check for updates
    /// - Parameters:
    ///   - apiKey: The API key
    ///   - appVersion: The app version
    ///   - sdkVersion: The SDK version
    ///   - distributionVersion: The distribution version
    ///   - environment: The environment
    ///   - deviceIdentifier: The device identifier
    ///   - completion: The completion handler
    func checkForUpdates(apiKey: String, appVersion: String, sdkVersion: String, distributionVersion: String, environment: Environment, deviceIdentifier: String?, completion: @escaping (() throws -> BundleInfo) -> Void)
    
    /// Download a file
    /// - Parameters:
    ///   - url: The URL to download from
    ///   - completion: The completion handler
    func download(url: URL, completion: @escaping (() throws -> URL) -> Void)
    
    /// Make a request
    /// - Parameters:
    ///   - endpoint: The endpoint to request
    ///   - completion: The completion handler
    func request<Response>(endpoint: Endpoint<Response>, completion: @escaping (() throws -> Response) -> Void)
}

enum APIError: Error {
    case noContent
    case invalidURL
    case invalidResponse
    case apiError(statusCode: Int, message: String?)
}

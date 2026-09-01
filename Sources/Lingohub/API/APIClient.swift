//
//  APIClient.swift
//
//
//  Created by Manfred Baldauf on 12.03.25.
//

import Foundation

/// Async HTTP client for the LingoHub CDN. Its methods are nonisolated async, so
/// networking and file handling run off the caller's actor (in particular, off the
/// main actor the SDK facade lives on).
final class APIClient: APIClientProtocol {
    private let basePath: String
    private let session: URLSession

    init(basePath: String, configuration: URLSessionConfiguration = URLSessionConfiguration.default) {
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil

        self.basePath = basePath
        self.session = URLSession(configuration: configuration)
    }
}

extension APIClient {
    func send<Response>(endpoint: Endpoint<Response>) async throws -> Response {
        guard let request = urlRequest(method: endpoint.method, path: endpoint.path, parameters: endpoint.parameters, headers: endpoint.headers) else {
            LingoHubLogger.shared.log("Failed to create URL request for path: \(endpoint.path)")
            throw APIError.invalidURL
        }

        LingoHubLogger.shared.log("Sending \(endpoint.method.rawValue) request to: \(request.url?.absoluteString ?? "nil")")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            LingoHubLogger.shared.log("Invalid response type: \(String(describing: response))")
            throw APIError.invalidResponse
        }

        LingoHubLogger.shared.log("Response status code: \(httpResponse.statusCode), \(data.count) bytes")

        switch httpResponse.statusCode {
        case 200:
            do {
                return try endpoint.decode(data)
            } catch {
                LingoHubLogger.shared.log("Failed to decode response: \(error)")
                throw error
            }
        case 204:
            LingoHubLogger.shared.log("No content response (204)")
            throw APIError.noContent
        default:
            LingoHubLogger.shared.log("Error response (\(httpResponse.statusCode))")
            var message: String?
            var infos: [String] = []
            if let errorResponse = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                message = errorResponse.message
                infos = errorResponse.infos
                LingoHubLogger.shared.log("Error message: \(message ?? "nil")")
            }
            throw APIError.apiError(statusCode: httpResponse.statusCode, message: message, infos: infos)
        }
    }

    private func urlRequest(method: HTTPMethod, path: String, parameters: [String: Any], headers: [String: String]) -> URLRequest? {
        var basePath = self.basePath + path
        if path.starts(with: "https://") { // absolute https URLs are used as-is
            basePath = path
        }

        var components = URLComponents(string: basePath)

        if method == .get, !parameters.isEmpty {
            components?.queryItems = parameters.compactMap { (key, value) in
                let stringValue = "\(value)"
                if stringValue.isEmpty {
                    return nil
                }
                return URLQueryItem(name: key, value: stringValue)
            }
        }

        guard let url = components?.url else {
            LingoHubLogger.shared.log("Failed to create URL from: \(basePath)")
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue

        if method != .get, !parameters.isEmpty {
            do {
                let data = try JSONSerialization.data(withJSONObject: parameters, options: [])
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = data
            } catch {
                LingoHubLogger.shared.log("Failed to serialize request body: \(error)")
            }
        }

        headers.forEach { key, value in
            request.setValue(value, forHTTPHeaderField: key)
        }

        return request
    }
}

/// Download support
extension APIClient {
    /// Downloads a file and moves it to a location the SDK controls.
    /// - Returns: The URL of the downloaded file; the caller deletes it when done.
    func download(from url: URL) async throws -> URL {
        LingoHubLogger.shared.log("Starting download from URL: \(url.absoluteString)")

        let (temporaryURL, response) = try await session.download(for: URLRequest(url: url))

        guard let httpResponse = response as? HTTPURLResponse else {
            LingoHubLogger.shared.log("Download failed: Invalid response type: \(String(describing: response))")
            throw APIError.invalidResponse
        }

        LingoHubLogger.shared.log("Download completed with status code: \(httpResponse.statusCode)")

        switch httpResponse.statusCode {
        case 200:
            // Move the system temporary file to a location we control before it is
            // cleaned up from under us.
            let fileManager = FileManager.default
            let destinationURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
            LingoHubLogger.shared.log("Download stored at: \(destinationURL.path)")
            return destinationURL
        default:
            var message: String?
            var infos: [String] = []
            if let errorData = try? Data(contentsOf: temporaryURL),
               let errorResponse = try? JSONDecoder().decode(ErrorResponse.self, from: errorData) {
                message = errorResponse.message
                infos = errorResponse.infos
            }
            LingoHubLogger.shared.log("Download failed with status code: \(httpResponse.statusCode), message: \(message ?? "None")")
            throw APIError.apiError(statusCode: httpResponse.statusCode, message: message, infos: infos)
        }
    }
}

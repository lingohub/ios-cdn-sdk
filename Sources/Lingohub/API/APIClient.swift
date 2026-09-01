//
//  APIClient.swift
//
//
//  Created by Manfred Baldauf on 12.03.25.
//

import Foundation

/// Per-task delegate enforcing the transfer policy while bytes are still arriving:
///
/// - Redirects to non-HTTPS URLs are refused. `URLSession` follows redirects before
///   any caller-side check can run, so an `https → http` hop would otherwise move the
///   transfer to cleartext despite the HTTPS-only policy.
/// - Once the declared (`Content-Length`) or actually received byte count exceeds
///   `maxBytes`, the task is cancelled, so an oversized response cannot consume
///   unbounded bandwidth and temporary disk space before post-download checks run.
final class DownloadGuardDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let maxBytes: Int64?
    private let lock = NSLock()
    private var _refusedInsecureRedirect = false
    private var _exceededSizeLimit = false

    var refusedInsecureRedirect: Bool { lock.lh_withLock { _refusedInsecureRedirect } }
    var exceededSizeLimit: Bool { lock.lh_withLock { _exceededSizeLimit } }

    init(maxBytes: Int64? = nil) {
        self.maxBytes = maxBytes
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        if request.url?.scheme?.lowercased() == "https" {
            completionHandler(request)
        } else {
            LingoHubLogger.shared.log("Refusing redirect to non-HTTPS URL")
            lock.lh_withLock { _refusedInsecureRedirect = true }
            completionHandler(nil)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let maxBytes else { return }
        let declaredTooLarge = totalBytesExpectedToWrite != NSURLSessionTransferSizeUnknown && totalBytesExpectedToWrite > maxBytes
        if totalBytesWritten > maxBytes || declaredTooLarge {
            lock.lh_withLock { _exceededSizeLimit = true }
            downloadTask.cancel()
        }
    }

    // Required by URLSessionDownloadDelegate; the async download(for:delegate:) API
    // delivers the finished file through its return value instead.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

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

        LingoHubLogger.shared.log("Sending \(endpoint.method.rawValue) request to: \(request.url?.lh_redactedDescription ?? "nil")")

        // The redirect guard keeps even the metadata exchange HTTPS-only end to end.
        let guardDelegate = DownloadGuardDelegate()
        let (data, response) = try await session.data(for: request, delegate: guardDelegate)

        guard let httpResponse = response as? HTTPURLResponse else {
            LingoHubLogger.shared.log("Invalid response type: \(String(describing: response))")
            throw APIError.invalidResponse
        }

        if guardDelegate.refusedInsecureRedirect {
            throw APIError.apiError(statusCode: 0, message: "Insecure redirect refused", infos: [])
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
    ///
    /// - Parameter maxSize: Compressed-size cap enforced while bytes arrive; the
    ///   transfer is aborted as soon as the declared or received size exceeds it.
    /// - Returns: The URL of the downloaded file; the caller deletes it when done.
    func download(from url: URL, maxSize: Int64?) async throws -> URL {
        LingoHubLogger.shared.log("Starting download from URL: \(url.lh_redactedDescription)")

        let guardDelegate = DownloadGuardDelegate(maxBytes: maxSize)
        let temporaryURL: URL
        let response: URLResponse
        do {
            (temporaryURL, response) = try await session.download(for: URLRequest(url: url), delegate: guardDelegate)
        } catch let error as URLError where error.code == .cancelled && guardDelegate.exceededSizeLimit {
            LingoHubLogger.shared.log("Download aborted: size limit exceeded")
            throw APIError.apiError(statusCode: 0, message: "Download exceeded the size limit", infos: [])
        }

        if guardDelegate.refusedInsecureRedirect {
            LingoHubLogger.shared.log("Download aborted: insecure redirect refused")
            throw APIError.apiError(statusCode: 0, message: "Insecure download redirect refused", infos: [])
        }

        // A very fast transfer can complete before the cancellation issued by the
        // delegate takes effect; the violation still fails the download.
        if guardDelegate.exceededSizeLimit {
            LingoHubLogger.shared.log("Download rejected: size limit exceeded")
            throw APIError.apiError(statusCode: 0, message: "Download exceeded the size limit", infos: [])
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            LingoHubLogger.shared.log("Download failed: Invalid response type: \(String(describing: response))")
            throw APIError.invalidResponse
        }

        LingoHubLogger.shared.log("Download completed with status code: \(httpResponse.statusCode)")

        switch httpResponse.statusCode {
        case 200:
            let fileManager = FileManager.default

            // Deterministic backstop for the streaming cap: transfers that finish
            // before the delegate's cancellation lands (or without progress
            // callbacks at all) are still rejected by their actual size on disk.
            if let maxSize {
                let attributes = try? fileManager.attributesOfItem(atPath: temporaryURL.path)
                let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
                guard size <= maxSize else {
                    LingoHubLogger.shared.log("Download rejected: \(size) bytes exceeds the size limit")
                    try? fileManager.removeItem(at: temporaryURL)
                    throw APIError.apiError(statusCode: 0, message: "Download exceeded the size limit", infos: [])
                }
            }

            // Move the system temporary file to a location we control before it is
            // cleaned up from under us.
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

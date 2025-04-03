//
//  APIClient.swift
//
//
//  Created by Manfred Baldauf on 12.03.25.
//

import Foundation

final class APIClient {
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
    func request<Response>(endpoint: Endpoint<Response>, completion: @escaping (() throws -> Response) -> Void) {
        LingohubLogger.shared.log("Creating URL request for endpoint: \(endpoint.path)")

        guard let request = urlRequest(method: endpoint.method, path: endpoint.path, parameters: endpoint.parameters, headers: endpoint.headers) else {
            LingohubLogger.shared.log("Failed to create URL request")
            DispatchQueue.main.async {
                completion { throw APIError.invalidURL }
            }
            return
        }

        LingohubLogger.shared.log("Created URL request: \(request.url?.absoluteString ?? "nil")")
        LingohubLogger.shared.log("Request method: \(request.httpMethod ?? "nil")")

        let task = session.dataTask(with: request) { data, response, error in
            LingohubLogger.shared.log("Received response for URL: \(request.url?.absoluteString ?? "nil")")

            if let error = error {
                LingohubLogger.shared.log("Network error: \(error.localizedDescription)")
                completion { throw error }
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                LingohubLogger.shared.log("Invalid response type: \(String(describing: response))")
                completion { throw APIError.invalidResponse }
                return
            }

            LingohubLogger.shared.log("Response status code: \(httpResponse.statusCode)")
            LingohubLogger.shared.log("Response headers: \(httpResponse.allHeaderFields)")

            do {
                guard let data = data, let statusCode = (response as? HTTPURLResponse)?.statusCode else {
                    LingohubLogger.shared.log("No data or status code in response")
                    throw APIError.invalidResponse
                }

                LingohubLogger.shared.log("Response data size: \(data.count) bytes")

                // Print a preview of the response data if it's not too large
                if let jsonString = String(data: data, encoding: .utf8) {
                    let truncatedString = String(jsonString.prefix(1000))
                    LingohubLogger.shared.log("Response data: \(truncatedString)")
                }

                switch statusCode {
                case 200:
                    LingohubLogger.shared.log("Successful response (200)")
                    do {
                        let response = try endpoint.decode(data)
                        LingohubLogger.shared.log("Successfully decoded response")
                        completion { return response }
                    } catch {
                        LingohubLogger.shared.log("Failed to decode response: \(error)")
                        throw error
                    }
                case 204:
                    LingohubLogger.shared.log("No content response (204)")
                    throw APIError.noContent
                default:
                    LingohubLogger.shared.log("Error response (\(statusCode))")
                    var message: String?
                    if let errorResponse = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                        message = errorResponse.message
                        LingohubLogger.shared.log("Error message: \(message ?? "nil")")
                    } else if let jsonString = String(data: data, encoding: .utf8) {
                        LingohubLogger.shared.log("Raw error response: \(jsonString)")
                    }
                    throw APIError.apiError(statusCode: statusCode, message: message)
                }
            } catch {
                LingohubLogger.shared.log("Error processing response: \(error)")
                completion { throw error }
            }
        }

        LingohubLogger.shared.log("Starting network request")
        task.resume()
    }


    private func urlRequest(method: HTTPMethod, path: String, parameters: [String: Any], headers: [String: String]) -> URLRequest? {
        LingohubLogger.shared.log("Creating URL request for path: \(path)")

        var basePath = self.basePath + path
        if (path.starts(with: "https://")) { //REMOVED HTTP - check if ok
            basePath = path
            LingohubLogger.shared.log("Using absolute path: \(basePath)")
        } else {
            LingohubLogger.shared.log("Using relative path: \(basePath)")
        }

        LingohubLogger.shared.log("Creating URL components from: \(basePath)")
        var components = URLComponents(string: basePath)

        if components == nil {
            LingohubLogger.shared.log("Failed to create URL components from: \(basePath)")
        }

        if method == .get, !parameters.isEmpty {
            LingohubLogger.shared.log("Adding query parameters for GET request")
            components?.queryItems = parameters.compactMap { (key, value) in
                let stringValue = "\(value)"
                if stringValue.isEmpty {
                    LingohubLogger.shared.log("Skipping empty parameter: \(key)")
                    return nil
                }
                LingohubLogger.shared.log("Adding query parameter: \(key)=\(stringValue)")
                return URLQueryItem(name: key, value: stringValue)
            }
        }

        guard let url = components?.url else {
            LingohubLogger.shared.log("Failed to create URL from components")
            return nil
        }

        LingohubLogger.shared.log("Created URL: \(url.absoluteString)")

        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        LingohubLogger.shared.log("Set HTTP method: \(method.rawValue)")

        if method != .get, !parameters.isEmpty {
            LingohubLogger.shared.log("Adding body parameters for \(method.rawValue) request")
            do {
                let data = try JSONSerialization.data(withJSONObject: parameters, options: [])
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = data

                if let bodyString = String(data: data, encoding: .utf8) {
                    LingohubLogger.shared.log("Request body: \(bodyString)")
                }
            } catch {
                LingohubLogger.shared.log("Failed to serialize request body: \(error)")
            }
        }

        if !headers.isEmpty {
            headers.forEach { key, value in
                request.setValue(value, forHTTPHeaderField: key)
            }
        }

        // Debug information
        LingohubLogger.shared.log("Final request URL: \(url.absoluteString)")

        if let body = request.httpBody, let bodyString = String(data: body, encoding: .utf8) {
            LingohubLogger.shared.log("Final request body: \(bodyString)")
        }

        return request
    }
}


/// Extension for download-related API endpoints
extension APIClient {
    /// Download a file
    /// - Parameters:
    ///   - url: The URL to download from
    ///   - completion: The completion handler

    func download(url: URL, completion: @escaping (() throws -> URL) -> Void) {
        LingohubLogger.shared.log("Starting download from URL: \(url.absoluteString)")
        let request = URLRequest(url: url)
        // For file downloads, we don't need to set Accept to application/json
        // as we're expecting binary data

        LingohubLogger.shared.log("Download request created with URL: \(url.absoluteString)")
        LingohubLogger.shared.log("Download request headers: \(request.allHTTPHeaderFields ?? [:])")

        let task = session.downloadTask(with: request) { temporaryURL, response, error in
            LingohubLogger.shared.log("Download task completed")

            do {
                if let error = error {
                    LingohubLogger.shared.log("Download error: \(error.localizedDescription)")
                    LingohubLogger.shared.log("Error details: \(error)")
                    throw error
                }

                guard let temporaryURL = temporaryURL else {
                    LingohubLogger.shared.log("Download failed: No temporary URL returned")
                    throw APIError.invalidResponse
                }
                LingohubLogger.shared.log("Temporary URL received: \(temporaryURL.path)")

                guard let httpResponse = response as? HTTPURLResponse else {
                    LingohubLogger.shared.log("Download failed: Invalid response type: \(String(describing: response))")
                    throw APIError.invalidResponse
                }

                let statusCode = httpResponse.statusCode
                LingohubLogger.shared.log("Download completed with status code: \(statusCode)")
                LingohubLogger.shared.log("Response headers: \(httpResponse.allHeaderFields)")

                switch statusCode {
                case 200:
                    // Create a copy of the temporary file in a location we control
                    // This is necessary because the system will delete the temporary file
                    // as soon as this completion handler returns
                    let fileManager = FileManager.default
                    let tempDir = fileManager.temporaryDirectory
                    let destinationURL = tempDir.appendingPathComponent(UUID().uuidString + ".zip")

                    LingohubLogger.shared.log("Copying temporary file from \(temporaryURL.path) to \(destinationURL.path)")

                    // Check if source file exists and get its size
                    if fileManager.fileExists(atPath: temporaryURL.path) {
                        do {
                            let attributes = try fileManager.attributesOfItem(atPath: temporaryURL.path)
                            if let fileSize = attributes[.size] as? UInt64 {
                                LingohubLogger.shared.log("Temporary file size: \(fileSize) bytes")
                                if fileSize == 0 {
                                    LingohubLogger.shared.log("Warning: Temporary file has zero size!")
                                }
                            }
                        } catch {
                            LingohubLogger.shared.log("Could not get temporary file attributes: \(error)")
                        }
                    } else {
                        LingohubLogger.shared.log("Warning: Temporary file does not exist at path: \(temporaryURL.path)")
                    }

                    try fileManager.copyItem(at: temporaryURL, to: destinationURL)

                    // Verify the file was copied successfully
                    guard fileManager.fileExists(atPath: destinationURL.path) else {
                        LingohubLogger.shared.log("Failed to copy temporary file")
                        throw APIError.invalidResponse
                    }

                    // Check destination file size
                    do {
                        let attributes = try fileManager.attributesOfItem(atPath: destinationURL.path)
                        if let fileSize = attributes[.size] as? UInt64 {
                            LingohubLogger.shared.log("Destination file size: \(fileSize) bytes")
                            if fileSize == 0 {
                                LingohubLogger.shared.log("Warning: Destination file has zero size!")
                            }
                        }
                    } catch {
                        LingohubLogger.shared.log("Could not get destination file attributes: \(error)")
                    }

                    LingohubLogger.shared.log("File copied successfully")
                    completion { return destinationURL }
                default:
                    var message: String?
                    if let errorData = try? Data(contentsOf: temporaryURL),
                       let errorResponse = try? JSONSerialization.jsonObject(with: errorData, options: []) as? [String: Any],
                       let errorMessage = errorResponse["message"] as? String {
                        message = errorMessage
                    }
                    LingohubLogger.shared.log("Download failed with status code: \(statusCode), message: \(message ?? "None")")

                    // Try to read the response body for more details
                    if let errorData = try? Data(contentsOf: temporaryURL),
                       let responseString = String(data: errorData, encoding: .utf8) {
                        LingohubLogger.shared.log("Error response body: \(responseString)")
                    }

                    throw APIError.apiError(statusCode: statusCode, message: message)
                }
            } catch {
                LingohubLogger.shared.log("Download completion handler error: \(error)")
                completion { throw error }
            }
        }

        LingohubLogger.shared.log("Starting download task")
        task.resume()
    }
}


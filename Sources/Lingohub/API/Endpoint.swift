//
//  Endpoint.swift
//
//  Created by Manfred Baldauf on 12.03.24.
//

import Foundation

/// HTTP method
public enum HTTPMethod: String {
    case options = "OPTIONS"
    case get     = "GET"
    case head    = "HEAD"
    case post    = "POST"
    case put     = "PUT"
    case patch   = "PATCH"
    case delete  = "DELETE"
    case trace   = "TRACE"
    case connect = "CONNECT"
}

/// API endpoint
final class Endpoint<Response> {
    let method: HTTPMethod
    let path: String
    let parameters: [String: Any]
    let headers: [String: String]
    let decode: (Data) throws -> Response

    init(method: HTTPMethod = .get, path: String, parameters: [String: Any] = [:], headers: [String: String] = [:], decode: @escaping (Data) throws -> Response) {
        self.method = method
        self.path = path
        self.parameters = parameters
        self.headers = headers
        self.decode = decode
    }
}

extension Endpoint where Response: Swift.Decodable {
    convenience init(method: HTTPMethod = .get, path: String, parameters: [String: Any] = [:], headers: [String: String] = [:]) {
        self.init(method: method, path: path, parameters: parameters, headers: headers) { data in
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            return try decoder.decode(Response.self, from: data)
        }
    }
}

extension Endpoint where Response == Void {
    convenience init(method: HTTPMethod = .get, path: String, parameters: [String: Any] = [:], headers: [String: String] = [:]) {
        self.init(method: method, path: path, parameters: parameters, headers: headers, decode: { _ in () })
    }
}

//
//  ErrorResponse.swift
//
//
//  Created by Manfred Baldauf on 12.03.25.
//

import Foundation

/// Error body returned by the LingoHub CDN.
///
/// The current API responds with an RFC 7807 problem-details body:
/// `{"type": "about:blank", "status": 401, "detail": "Unauthorized", "errors": [{"field": "AUTHORIZATION", "infos": ["CDN_KEY_NOT_FOUND"]}]}`
///
/// The legacy `{"error_message": "..."}` format is still accepted as a fallback.
struct ErrorResponse: Decodable {
    let message: String?
    /// Structured error codes from the problem-details body (e.g. DISTRIBUTION_NOT_FOUND).
    let infos: [String]

    private struct Problem: Decodable {
        struct ErrorDetail: Decodable {
            let field: String?
            let infos: [String]?
        }
        let detail: String?
        let errors: [ErrorDetail]?
    }

    private struct Legacy: Decodable {
        let errorMessage: String

        enum CodingKeys: String, CodingKey {
            case errorMessage = "error_message"
        }
    }

    init(from decoder: Decoder) throws {
        if let legacy = try? Legacy(from: decoder) {
            message = legacy.errorMessage
            infos = []
            return
        }

        let problem = try Problem(from: decoder)
        let infos = (problem.errors ?? []).flatMap { $0.infos ?? [] }
        self.infos = infos
        switch (problem.detail, infos.isEmpty) {
        case (let detail?, false):
            message = "\(detail) (\(infos.joined(separator: ", ")))"
        case (let detail?, true):
            message = detail
        case (nil, false):
            message = infos.joined(separator: ", ")
        case (nil, true):
            message = nil
        }
    }
}

//
//  ErrorResponse.swift
//
//
//  Created by Manfred Baldauf on 12.03.25.
//

import Foundation

/// Error body returned by the Lingohub CDN.
///
/// The current API responds with an RFC 7807 problem-details body:
/// `{"type": "about:blank", "status": 401, "detail": "Unauthorized", "errors": [{"field": "AUTHORIZATION", "infos": ["CDN_KEY_NOT_FOUND"]}]}`
///
/// The legacy `{"error_message": "..."}` format is still accepted as a fallback.
struct ErrorResponse: Decodable {
    let message: String?

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
            return
        }

        let problem = try Problem(from: decoder)
        let infos = (problem.errors ?? []).flatMap { $0.infos ?? [] }
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

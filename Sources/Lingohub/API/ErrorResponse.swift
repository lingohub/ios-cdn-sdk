//
//  ErrorResponse.swift
//
//
//  Created by Manfred Baldauf on 12.03.25.
//

import Foundation

struct ErrorResponse: Codable {
    let message: String
    
    private enum CodingKeys: String, CodingKey {
        case message = "error_message"
    }
}

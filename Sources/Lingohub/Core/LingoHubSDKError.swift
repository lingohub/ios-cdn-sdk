//
//  LingoHubSDKError.swift
//
//
//  Created by Manfred Baldauf on 12.03.25.
//

import Foundation

/**
 The error type returned by LingoHub
 */
public enum LingoHubSDKError: Error {
    /// An unknown error occurred.
    case unknown
    /// The apiKey is missing.
    case invalidApiKey
    /// The appVersion is missing.
    case invalidAppVersion
    /// The sdkVersion is missing.
    case invalidSdkVersion
    /// An error with the API occurred.
    ///
    /// `statusCode` is the HTTP status (0 for local errors where no response was received),
    /// `message` is a human-readable description, and `errorCodes` carries the CDN's
    /// structured error codes (e.g. `CDN_KEY_NOT_FOUND`, `USAGE_LIMIT_EXCEEDED`) so you can
    /// react programmatically without parsing the message. Empty when the response carried none.
    case apiError(statusCode: Int, message: String?, errorCodes: [String])
}


extension LingoHubSDKError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unknown:
            return "An unknown error occurred."
        case .invalidApiKey:
            return "The apiKey is missing."
        case .invalidAppVersion:
            return "The appVersion is missing."
        case .invalidSdkVersion:
            return "The sdkVersion is missing."
        case .apiError(let statusCode, let message, _):
            if let message = message {
                return message
            }
            return "API-Error with code \"\(statusCode)\" occurred"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .invalidApiKey, .invalidAppVersion, .invalidSdkVersion:
            return "Use the configure method to provide the missing data"
        default:
            return nil
        }
    }
}

extension LingoHubSDKError: CustomNSError {
    public var errorCode: Int {
        switch self {
        case .apiError(let statusCode, _, _):
            return statusCode
        default:
            return -1
        }
    }
}



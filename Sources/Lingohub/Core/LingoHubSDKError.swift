//
//  LingohubSDKError.swift
//
//
//  Created by Manfred Baldauf on 12.03.25.
//

import Foundation

/**
 The error type returned by Lingohub
 */
public enum LingohubSDKError: Error {
    /// An unknown error occured.
    case unknown
    /// The apiKey is missing.
    case invalidApiKey
    /// The appVersion is missing.
    case invalidAppVersion
    /// The sdkVersion is missing.
    case invalidSdkVersion
    /// An error with the API occured. See `statusCode` and `message` for specific information
    case apiError(statusCode: Int, message: String?)
}


extension LingohubSDKError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unknown:
            return "An unknown error occured."
        case .invalidApiKey:
            return "The apiKey is missing."
        case .invalidAppVersion:
            return "The appVersion is missing."
        case .invalidSdkVersion:
            return "The sdkVersion is missing."
        case .apiError(let statusCode, let message):
            if let message = message {
                return message
            }
            return "API-Error with code \"\(statusCode)\" occured"
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

extension LingohubSDKError: CustomNSError {
    public var errorCode: Int {
        switch self {
        case .apiError(let statusCode, _):
            return statusCode
        default:
            return -1
        }
    }
}



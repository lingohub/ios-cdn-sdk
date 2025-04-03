//
//  String+Localization.swift
//
//  Created by Manfred Baldauf on 12.03.24.
//

import Foundation
import Swift
@testable import Lingohub // Make SDK internals testable

extension String {

    @MainActor static func localized(_ key: String, tableName: String? = nil) -> String {
        return NSLocalizedString(key, tableName: tableName, bundle: Bundle.module, value: key, comment: "")
    }

    @MainActor static func localizedFormat(_ key: String, _ args: CVarArg...) -> String {
        return withVaList(args) { params -> String in
            return NSString(format: String.localized(key), arguments: params) as String
        }
    }
}

@available(swift, obsoleted: 1.0)
@objc public extension NSString {

    @MainActor static func localized(_ key: String, tableName: String? = nil) -> NSString {
        return NSLocalizedString(key, tableName: tableName, bundle: Bundle.module, value: key, comment: "") as NSString

    }
}

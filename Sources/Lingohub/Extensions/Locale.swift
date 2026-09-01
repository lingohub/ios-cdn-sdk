//
//  Locale.swift
//

import Foundation

extension Locale {
    /// The current system language code (ISO 639-1), using the non-deprecated API where available.
    static var lingohubLanguageCode: String? {
        if #available(iOS 16.0, macOS 13.0, *) {
            return Locale.current.language.languageCode?.identifier
        } else {
            return Locale.current.languageCode
        }
    }
}

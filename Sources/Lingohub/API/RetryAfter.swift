//
//  RetryAfter.swift
//

import Foundation

/// Parses the HTTP `Retry-After` header (RFC 9110, section 10.2.3).
enum RetryAfter {
    /// The delay in seconds the header value asks for: delay-seconds (`"120"`), or the
    /// time until an HTTP-date (`"Wed, 21 Oct 2026 07:28:00 GMT"`, 0 once it has passed).
    /// Nil when the value is missing or malformed.
    static func delay(fromHeaderValue value: String?, now: Date = Date()) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else {
            return nil
        }
        if value.utf8.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }) {
            return TimeInterval(value)
        }
        guard let date = httpDate(from: value) else {
            return nil
        }
        return max(0, date.timeIntervalSince(now))
    }

    /// Only the IMF-fixdate form: RFC 9110 asks recipients to accept the two obsolete
    /// forms too, but no server this SDK talks to sends them.
    private static func httpDate(from value: String) -> Date? {
        // Created per call: parsing runs only for a failed response that carries a date
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.date(from: value)
    }
}

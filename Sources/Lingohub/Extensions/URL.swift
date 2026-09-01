//
//  URL.swift
//

import Foundation

extension URL {
    /// The URL reduced to scheme, host, and path — query and fragment stripped.
    ///
    /// Release download URLs are presigned: their query string carries credentials.
    /// Logs must only ever contain this redacted form, never the full URL.
    var lh_redactedDescription: String {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            return "\(scheme ?? "?")://\(host ?? "?")\(path)"
        }
        components.query = nil
        components.fragment = nil
        return components.string ?? "\(scheme ?? "?")://\(host ?? "?")\(path)"
    }
}

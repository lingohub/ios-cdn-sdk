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

    /// macOS metadata that archives and copied folders carry along (resource forks,
    /// AppleDouble files, Finder state). Never localization content, so it must not
    /// influence layout decisions, validation, or merging.
    var lh_isMacOSMetadata: Bool {
        let name = lastPathComponent
        return name == "__MACOSX" || name == ".DS_Store" || name.hasPrefix("._")
    }

    /// Whether a directory exists at this file URL.
    var lh_isDirectory: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

//
//  LocalizedStringResource+LingoHub.swift
//

import Foundation

@available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *)
public extension String {
    /**
     Creates a string from `resource`, looked up in ``Foundation/Bundle/lingohub`` when it
     targets your app bundle. Shorthand for
     `String(localized: LingoHubSDK.shared.resolve(resource))`.

     ```swift
     let title = String(lh: "welcome_message")
     let status = String(lh: "\(unread) unread messages")
     ```

     Xcode extracts the literal into your String Catalog, as it does for
     `String(localized:)`.
     */
    init(lh resource: LocalizedStringResource) {
        self.init(localized: LingoHubResourceResolver.resolve(resource))
    }
}

/// Retargets resources that look up the app bundle to `Bundle.lingohub`
/// (`LingoHubSDK.resolve(_:)`, `String(lh:)`, `Text(lh:)`).
@available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *)
enum LingoHubResourceResolver {
    static func resolve(_ resource: LocalizedStringResource, store: LocalizationCacheManager = .shared) -> LocalizedStringResource {
        guard let target = store.lingohubBundle, targetsAppBundle(resource.bundle, store: store) else {
            return resource
        }
        guard let retargeted = resource.lh_retargeted(to: target.bundleURL) else {
            LingoHubLogger.shared.log("LocalizedStringResource '\(resource.key)' could not be retargeted, using it unchanged")
            return resource
        }
        return retargeted
    }

    /// Merged bundles mirror the app bundle only; resources of frameworks or Swift
    /// packages must keep their own bundle. A resource that points at a merged bundle
    /// (resolved before a newer release or a language switch) is retargeted as well.
    private static func targetsAppBundle(_ bundle: LocalizedStringResource.BundleDescription, store: LocalizationCacheManager) -> Bool {
        switch bundle {
        case .main:
            return true
        case .forClass(let aClass):
            return isAppBundle(Bundle(for: aClass).bundleURL, store: store)
        case .atURL(let url):
            return isAppBundle(url, store: store) || isMergedBundle(url, store: store)
        @unknown default:
            return false
        }
    }

    /// A resource created with the default bundle reports `.atURL(Bundle.main.bundleURL)`,
    /// not `.main`. The base bundle is `Bundle.main` outside of tests.
    private static func isAppBundle(_ url: URL, store: LocalizationCacheManager) -> Bool {
        let path = url.standardizedFileURL.path
        return path == Bundle.main.bundleURL.standardizedFileURL.path
            || path == store.baseBundle.bundleURL.standardizedFileURL.path
    }

    private static func isMergedBundle(_ url: URL, store: LocalizationCacheManager) -> Bool {
        guard let folderPath = store.mergedBundlesFolderUrl?.standardizedFileURL.path else {
            return false
        }
        return url.standardizedFileURL.path.hasPrefix(folderPath + "/")
    }
}

@available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *)
extension LocalizedStringResource {
    /// This resource looked up in the bundle at `bundleURL`, with the same key, table,
    /// default value, interpolation arguments, and locale.
    ///
    /// `bundle` is get-only, so the resource is rebuilt through its `Codable`
    /// representation, which carries the target as `bundleURL` plus a sandbox extension
    /// token for it. The token is dropped: it grants access to the original bundle, and
    /// merged bundles live in the app's own container. The representation is Apple's,
    /// not a documented contract, hence nil when it no longer round-trips.
    func lh_retargeted(to bundleURL: URL) -> LocalizedStringResource? {
        do {
            let encoded = try JSONEncoder().encode(self)
            guard var representation = try JSONSerialization.jsonObject(with: encoded) as? [String: Any],
                  representation["bundleURL"] != nil else {
                return nil
            }
            representation["bundleURL"] = bundleURL.absoluteString
            representation.removeValue(forKey: "sandboxExtensionToken")

            let patched = try JSONSerialization.data(withJSONObject: representation)
            var retargeted = try JSONDecoder().decode(LocalizedStringResource.self, from: patched)
            guard case .atURL(let url) = retargeted.bundle,
                  url.standardizedFileURL.path == bundleURL.standardizedFileURL.path else {
                return nil
            }
            // The Codable form flattens the locale (`.autoupdatingCurrent`, user
            // preferences); keep the caller's.
            retargeted.locale = locale
            return retargeted
        } catch {
            return nil
        }
    }
}

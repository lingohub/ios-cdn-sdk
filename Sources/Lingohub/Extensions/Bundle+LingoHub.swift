//
//  Bundle+LingoHub.swift
//

import Foundation

public extension Bundle {
    /**
     The bundle to pass to Swift-native localization APIs so they show downloaded
     LingoHub translations:

     ```swift
     Text("welcome_message", bundle: .lingohub)
     String(localized: "welcome_message", bundle: .lingohub)
     AttributedString(localized: "welcome_message", bundle: .lingohub)
     LocalizedStringResource("welcome_message", bundle: .atURL(Bundle.lingohub.bundleURL))
     ```

     These APIs never call `Bundle.localizedString(forKey:value:table:)`, the one
     method ``LingoHubSDK/swizzleMainBundle()`` intercepts, so swizzling cannot reach
     them. While a release is active, this bundle holds every string table of your app
     bundle with the release's entries laid over it: keys the release does not contain
     resolve to your bundled strings, `.stringsdict` plurals included. A language set
     with ``LingoHubSDK/setLanguage(_:)`` is served whatever locale the lookup uses.
     Without an active release (before the first download, or after an app update
     discarded it), this is `Bundle.main`.

     The value changes when a release is activated or the language is switched, so read
     it where the string is looked up, for example in a view's `body`, instead of
     storing it.
     */
    static var lingohub: Bundle {
        return LocalizationCacheManager.shared.lingohubBundle ?? .main
    }
}

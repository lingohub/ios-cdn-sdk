//
//  Text+LingoHub.swift
//

#if canImport(SwiftUI)
import SwiftUI

@available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *)
public extension Text {
    /**
     Creates a text view that displays `resource`, looked up in ``Foundation/Bundle/lingohub``
     when it targets your app bundle. Shorthand for
     `Text(LingoHubSDK.shared.resolve(resource))`.

     ```swift
     Text(lh: "welcome_message")
     Text(lh: "\(unread) unread messages")
     ```

     Xcode extracts the literal into your String Catalog, as it does for `Text("…")`.
     */
    init(lh resource: LocalizedStringResource) {
        self.init(LingoHubResourceResolver.resolve(resource))
    }
}
#endif

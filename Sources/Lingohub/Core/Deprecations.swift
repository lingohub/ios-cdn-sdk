//
//  Deprecations.swift
//
//  Backwards compatibility for the pre-1.1.0 type names. The public API was renamed
//  to the LingoHub brand spelling in 1.1.0; these aliases keep 1.0.0 integrations
//  compiling while nudging them to the new names.
//

import Foundation

@available(*, deprecated, renamed: "LingoHubSDK")
public typealias LingohubSDK = LingoHubSDK

@available(*, deprecated, renamed: "LingoHubSDKError")
public typealias LingohubSDKError = LingoHubSDKError

public extension Notification.Name {
    /// Deprecated spelling of ``LingoHubDidUpdateLocalization``. Both resolve to the
    /// same underlying notification name, so existing observers keep working.
    @available(*, deprecated, renamed: "LingoHubDidUpdateLocalization")
    static var LingohubDidUpdateLocalization: Notification.Name {
        return .LingoHubDidUpdateLocalization
    }
}

@available(swift, obsoleted: 1.0)
@objc public extension NSNotification {
    /// Deprecated Objective-C spelling of `LingoHubDidUpdateLocalization`. Both resolve
    /// to the same underlying notification name, so existing observers keep working.
    @available(*, deprecated, renamed: "LingoHubDidUpdateLocalization")
    static var LingohubDidUpdateLocalization: NSString {
        return NSString(string: LingoHubConstants.updateNotification)
    }
}

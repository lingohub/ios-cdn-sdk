//
//  Bundle+Extensions.swift
//
//
//  Created by Manfred Baldauf on 12.03.25.
//

import Foundation

extension Bundle {
    private static var originalSelector: Selector {
        return #selector(localizedString(forKey:value:table:))
    }

    private static var customSelector: Selector {
        return #selector(customLocalizedString(forKey:value:table:))
    }

    // Guards the method exchange: swizzle/deswizzle must be balanced, otherwise an
    // unpaired call would silently invert which implementation is active.
    private static let swizzleLock = NSLock()
    // Invariant: only ever read or written while holding `swizzleLock`.
    // `nonisolated(unsafe)` because the lock provides the synchronization the
    // compiler cannot see; without it this is an error in Swift 6 language mode.
    nonisolated(unsafe) private static var isSwizzled = false

    static func swizzle() {
        swizzleLock.lh_withLock {
            guard !isSwizzled else { return }
            isSwizzled = true
            exchangeImplementation(fromSelector: originalSelector, toSelector: customSelector)
        }
    }

    @objc static func deswizzle() {
        swizzleLock.lh_withLock {
            guard isSwizzled else { return }
            isSwizzled = false
            exchangeImplementation(fromSelector: customSelector, toSelector: originalSelector)
        }
    }

    private static func exchangeImplementation(fromSelector: Selector, toSelector: Selector) {
        guard let fromMethod = class_getInstanceMethod(self, fromSelector) else { return }
        guard let toMethod = class_getInstanceMethod(self, toSelector) else { return }

        if class_addMethod(self, fromSelector, method_getImplementation(toMethod), method_getTypeEncoding(toMethod)) {
            class_replaceMethod(self, toSelector, method_getImplementation(fromMethod), method_getTypeEncoding(fromMethod))
        } else {
            method_exchangeImplementations(fromMethod, toMethod)
        }
    }

    // Passed as the `value` fallback when probing the update bundle: the original
    // implementation echoes the value back when a key is missing, so an improbable
    // marker string detects "not found" exactly - without shadowing the app bundle's
    // own translations the way a caller-supplied `value` would.
    private static let lingoHubMissingMarker = "\u{200B}LingoHub.missing\u{200B}"

    // `Bundle.localizedString(forKey:value:table:)` is documented thread-safe and apps call
    // it from arbitrary threads, so this replacement must not touch main-actor state.
    // It only reads the thread-safe `LocalizationCacheManager`.
    @objc private func customLocalizedString(forKey key: String, value: String?, table: String?) -> String {
        let store = LocalizationCacheManager.shared
        let effectiveTableName = table ?? "Localizable"

        if store.isSwizzled(bundlePath: self.bundlePath) {
            let language = store.language

            // 1. Check the LingoHub cache for .strings first
            if let cachedString = store.getString(forKey: key, tableName: effectiveTableName, language: language) {
                return cachedString
            }

            // 2. Try the system localization mechanism on the update bundle
            //    (handles .stringsdict plurals). `languageBundle(for:)` is nil while
            //    no downloaded release is active.
            if let languageBundle = store.languageBundle(for: language) {
                // Since methods are swizzled, calling our selector executes the
                // original implementation for that bundle instance.
                let probe = languageBundle.customLocalizedString(forKey: key, value: Bundle.lingoHubMissingMarker, table: effectiveTableName)
                if probe != Bundle.lingoHubMissingMarker {
                    return probe
                }
                LingoHubLogger.shared.log("[BUNDLE] Key '\(key)' not found in update bundle, falling back.")
            }
        }

        // 3. Fallback: the original localizedString on the original bundle (self),
        // with the caller's own `value`. Handles: not swizzled, no update bundle
        // active, or key not found in the update bundle.
        return self.customLocalizedString(forKey: key, value: value, table: effectiveTableName)
    }
}

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
    private static var isSwizzled = false

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

    // `Bundle.localizedString(forKey:value:table:)` is documented thread-safe and apps call
    // it from arbitrary threads, so this replacement must not touch main-actor state.
    // It only reads the thread-safe `LocalizationCacheManager`.
    @objc private func customLocalizedString(forKey key: String, value: String?, table: String?) -> String {
        let store = LocalizationCacheManager.shared
        let effectiveTableName = table ?? "Localizable"

        let isSwizzled = store.isSwizzled(bundlePath: self.bundlePath)

        // 1. Check the Lingohub cache for .strings first
        if isSwizzled, store.isUpdateActive {
            if let cachedString = store.getString(forKey: key, tableName: effectiveTableName, language: store.language) {
                // Found simple string in Lingohub cache
                LingohubLogger.shared.log("[BUNDLE] Found key '\(key)' in cache.")
                return cachedString
            }
            LingohubLogger.shared.log("[BUNDLE] Key '\(key)' NOT in cache. Checking update bundle...")
            // Not found in .strings cache. Proceed to check update bundle with system mechanism.
        }

        // 2. Try the system localization mechanism on the update bundle (handles .stringsdict)
        if isSwizzled, store.isUpdateActive, let updateBundle = store.updateBundle {
            LingohubLogger.shared.log("[BUNDLE] Update bundle exists at: \(updateBundle.bundleURL.path)")
            // Get the specific language bundle within the update bundle
            let specificUpdateBundle = updateBundle.languageBundle(for: store.language)
            LingohubLogger.shared.log("[BUNDLE] Using specific lang bundle: \(specificUpdateBundle.bundleURL.path) for language '\(store.language ?? "nil")'")

            // Call the original implementation ON the specificUpdateBundle.
            // Since methods are swizzled, calling our selector executes the original code for that bundle instance.
            let systemResult = specificUpdateBundle.customLocalizedString(forKey: key, value: value, table: effectiveTableName)
            LingohubLogger.shared.log("[BUNDLE] Original lookup on specific update bundle returned: '\(systemResult)'")

            // NSLocalizedString returns the key if not found. Check if we found something different.
            // Also consider if an explicit non-empty 'value' was passed as fallback.
            if systemResult != key || (value != nil && !value!.isEmpty) {
                LingohubLogger.shared.log("[BUNDLE] Found '\(key)' via system localization in update bundle. Returning '\(systemResult)'")
                return systemResult
            }
            LingohubLogger.shared.log("[BUNDLE] Key '\(key)' seems not found in update bundle (result matches key), falling back.")
        } else if !isSwizzled {
            LingohubLogger.shared.log("[BUNDLE] Bundle \(self.bundleURL.lastPathComponent) is not swizzled, using original lookup.")
        }

        // 3. Fallback: Call the original localizedString on the original bundle (self).
        // Handles cases: not swizzled, update bundle not used, or key not found in update bundle.
        let fallbackResult = self.customLocalizedString(forKey: key, value: value, table: effectiveTableName)
        return fallbackResult
    }

    // Helper to get the language-specific bundle path (.lproj)
    internal func languageBundle(for language: String?) -> Bundle {
        // Default to self if specific language bundle not found
        guard let language = language,
              let languageBundlePath = self.path(forResource: language, ofType: "lproj"),
              let languageBundle = Bundle(path: languageBundlePath) else {
            LingohubLogger.shared.log("[BUNDLE] Lang bundle NOT FOUND in bundle \(self.bundleURL.lastPathComponent), using base.")
            return self
        }
        return languageBundle
    }
}

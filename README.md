# Lingohub iOS SDK

[![License](https://img.shields.io/github/license/lingohub/ios-cdn-sdk?style=flat-square)](./LICENSE)
[![Swift Package Manager](https://img.shields.io/badge/SPM-compatible-brightgreen?style=flat-square)](https://swift.org/package-manager/)
[![Platform](https://img.shields.io/badge/platform-iOS%2014%2B-blue?style=flat-square)](#requirements)

A Swift SDK for over-the-air (OTA) localization with [Lingohub](https://lingohub.com). Update your app's translations without releasing a new app version.

## Features

* 🚀 Over-the-air localization updates via the Lingohub CDN
* 🔄 Runtime language switching
* 📱 Works with `.strings`, `.stringsdict`, and String Catalog (`.xcstrings`) projects
* 🛠 Method swizzling for seamless integration — keep using `NSLocalizedString` as usual
* 🔒 Descriptive error reporting
* 🕵️ Ships a privacy manifest (`PrivacyInfo.xcprivacy`)
* 📝 Optional debug logging

## How it works

1. Publish a release for a **Distribution** in Lingohub.
2. The SDK asks the Lingohub CDN whether a release matching your app version is available. Releases can target app version ranges, with an optional fallback release for all other versions.
3. If there is a new release, the SDK downloads it and serves the updated strings through the standard localization APIs (when swizzling is enabled).
4. Downloaded translations are cached on disk and discarded automatically when your app version changes, so a fresh app release always starts from its bundled strings.

If nothing has been published yet for your app version and environment, the SDK simply reports that no update is available — that is a normal state, not an error.

## Requirements

* iOS 14.0+
* Swift 5.9+ / Xcode 15+

> The SwiftUI snippets below use the two-parameter `onChange(of:)`, which requires iOS 17. On iOS 14–16, use the single-parameter variant as noted.

## Installation

### Swift Package Manager

In Xcode: **File → Add Package Dependencies…** and enter:

```
https://github.com/lingohub/ios-cdn-sdk.git
```

Or add it to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/lingohub/ios-cdn-sdk.git", from: "1.0.0")
]
```

## Get your API key

1. In Lingohub, open your project and create a **Distribution** (type: *Mobile SDK iOS*).
2. Publish a release for the environment you want to use (or mark one release as the fallback).
3. Copy the distribution's CDN API key — it starts with `cdn_`.

See the [Lingohub CDN documentation](https://developers.lingohub.com/reference/distributions) for details.

## Quick Start

### SwiftUI

```swift
import SwiftUI
import Lingohub

@main
struct YourApp: App {
    @SwiftUI.Environment(\.scenePhase) private var scenePhase

    init() {
        // Configure the SDK with your CDN API key
        LingohubSDK.shared.configure(withApiKey: "cdn_YOUR-API-KEY")

        // Enable method swizzling for automatic localization
        LingohubSDK.shared.swizzleMainBundle()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                // Check for updates when the app becomes active
                LingohubSDK.shared.update()
            }
        }
    }
}
```

> Note: the SDK exports its own `Environment` type, so the SwiftUI property wrapper needs to be written as `@SwiftUI.Environment`.
>
> On iOS 14–16, use the single-parameter `onChange`: `.onChange(of: scenePhase) { newPhase in ... }`

### UIKit

```swift
import Lingohub

func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    // Configure the SDK with your CDN API key
    LingohubSDK.shared.configure(withApiKey: "cdn_YOUR-API-KEY")

    // Enable method swizzling for automatic localization
    LingohubSDK.shared.swizzleMainBundle()

    return true
}

func applicationDidBecomeActive(_ application: UIApplication) {
    // Check for updates when the app becomes active
    LingohubSDK.shared.update()
}
```

### Use your strings as usual

With swizzling enabled, keep using `NSLocalizedString` — the SDK serves the updated translation when one is available and falls back to your bundled strings otherwise:

```swift
NSLocalizedString("welcome_message", comment: "Welcome message")
```

## File formats

* **`.strings`** — fully supported.
* **`.stringsdict`** (plurals) — supported through the swizzled `NSLocalizedString` path. The manual `localizedString(forKey:tableName:)` API reads `.strings` files only.
* **String Catalogs (`.xcstrings`)** — supported. Xcode compiles String Catalogs into `.strings`/`.stringsdict` at build time, so the swizzled lookup works unchanged. Lingohub delivers the updated files in the same compiled formats.

## Configuration

```swift
LingohubSDK.shared.configure(
    withApiKey: "cdn_YOUR-API-KEY",
    environment: .production,
    logLevel: .full // detailed logging, not recommended for production
)
```

| Parameter | Example | Description | Default |
|-----------|---------|-------------|---------|
| `appVersion` | `"1.2.0"` | The version of your app, used for release targeting | `CFBundleShortVersionString` from your Info.plist |
| `environment` | `.production` | Environment to check (`.production`, `.staging`, `.development`, `.test`) | `.production` |
| `logLevel` | `.none` | Debug logging (`.none` or `.full`) | `.none` |

The `appVersion` matters: releases in Lingohub can target app version ranges, and the CDN picks the release matching the version the SDK reports.

## Advanced Usage

### Switch languages at runtime

```swift
// Override with an ISO 639-1 language code
LingohubSDK.shared.setLanguage("de")

// Back to the system language
LingohubSDK.shared.setSystemLanguage()
```

The override applies to Lingohub-served strings for the current app session. Views that are already on screen need to be re-rendered to pick up the new language, for example:

```swift
struct ContentView: View {
    @State private var refreshTrigger = false

    var body: some View {
        VStack {
            Text(NSLocalizedString("welcome_message", comment: ""))
            Button("Deutsch") {
                LingohubSDK.shared.setLanguage("de")
                refreshTrigger.toggle()
            }
        }
        .id(refreshTrigger) // re-render on language change
    }
}
```

### Manual localization

If you prefer not to use method swizzling:

```swift
func getLocalizedString(for key: String, tableName: String? = nil) -> String {
    if let localizedString = LingohubSDK.shared.localizedString(forKey: key, tableName: tableName) {
        return localizedString
    }
    return NSLocalizedString(key, tableName: tableName, comment: "")
}
```

### Update notifications

Via `NotificationCenter`:

```swift
NotificationCenter.default.addObserver(
    forName: .LingohubDidUpdateLocalization,
    object: nil,
    queue: .main
) { [weak self] _ in
    self?.updateUI()
}
```

Via callback — `true` means new translations were downloaded and are active, `false` means there was nothing new:

```swift
LingohubSDK.shared.update { result in
    switch result {
    case .success(let updated):
        if updated {
            // new translations are active, refresh your UI if needed
        }
    case .failure(let error):
        print("Lingohub update failed: \(error.localizedDescription)")
    }
}
```

Callbacks are delivered on the main queue.

### Reduce network requests

The CDN check is a network request, and CDN usage counts towards your plan. If you check on every foreground activation, consider throttling:

```swift
import Foundation

final class UpdateThrottle {
    private let userDefaults = UserDefaults.standard
    private let lastFetchKey = "lingohub_last_fetch_time"
    private let minimumInterval: TimeInterval = 24 * 60 * 60 // once a day

    func shouldCheckForUpdates() -> Bool {
        let lastFetchTime = userDefaults.double(forKey: lastFetchKey)
        return Date().timeIntervalSince1970 - lastFetchTime >= minimumInterval
    }

    func markChecked() {
        userDefaults.set(Date().timeIntervalSince1970, forKey: lastFetchKey)
    }
}
```

```swift
.onChange(of: scenePhase) { _, newPhase in
    if newPhase == .active, updateThrottle.shouldCheckForUpdates() {
        LingohubSDK.shared.update { result in
            switch result {
            case .success:
                updateThrottle.markChecked()
            case .failure:
                break // try again next time
            }
        }
    }
}
```

## Error handling

The result callback reports errors as `LingohubSDKError`:

```swift
LingohubSDK.shared.update { result in
    switch result {
    case .success(let updated):
        print(updated ? "Translations updated" : "Already up to date")
    case .failure(let error):
        switch error {
        case .invalidApiKey:
            print("API key is missing — call configure first")
        case .invalidAppVersion:
            print("App version is missing")
        case .invalidSdkVersion:
            print("SDK version is missing")
        case .apiError(let statusCode, let message):
            print("API error \(statusCode): \(message ?? "no message")")
        case .unknown:
            print("An unknown error occurred")
        }
    }
}
```

### Troubleshooting

* **`update` keeps reporting `false` and nothing changes** — most likely no release is published yet for your app version and environment. Publish a release in your Distribution (or mark one as the fallback), and double-check that the `environment` you configure matches the release's environment.
* **API error 401** — the CDN key is missing, invalid, or was revoked. The error message contains the reason (for example `CDN_KEY_NOT_FOUND`).
* **API error 429** — your CDN usage budget is exhausted. Throttle update checks (see above).

## Privacy

The SDK includes a `PrivacyInfo.xcprivacy` manifest, which Xcode merges into your app's privacy report automatically. What the SDK touches:

* `UserDefaults` — stores the installed release ID, app version, and language override.
* A random installation identifier stored in the keychain — sent to the CDN as an anonymous client identifier for usage metering. It is not linked to user identity and not used for tracking.
* Downloaded translation bundles — stored in the app's container.

## Demo app

The [DemoAppLingoHub](DemoAppLingoHub/) project in this repository shows a complete SwiftUI integration, including runtime language switching and update notifications. Open it in Xcode, insert your CDN API key in `LingohubApp.swift`, and run.

## Support

For bug reports and feature requests, please open an issue on GitHub.

## License

Apache License Version 2.0, January 2004. More info in the [LICENSE](./LICENSE) file.

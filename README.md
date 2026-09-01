# LingoHub iOS SDK

[![Release](https://img.shields.io/github/v/release/lingohub/ios-cdn-sdk?style=flat-square)](https://github.com/lingohub/ios-cdn-sdk/releases)
[![License](https://img.shields.io/github/license/lingohub/ios-cdn-sdk?style=flat-square)](./LICENSE)
[![Platform](https://img.shields.io/badge/platform-iOS%2015%2B-blue?style=flat-square)](#requirements)

A Swift SDK for over-the-air (OTA) localization with [LingoHub](https://lingohub.com). Update your app's translations without releasing a new app version.

**Contents:** [How it works](#how-it-works) · [Installation](#installation) · [Get your API key](#get-your-api-key) · [Quick Start](#quick-start) · [Configuration](#configuration) · [Advanced Usage](#advanced-usage) · [Error handling](#error-handling) · [Privacy](#privacy) · [Sample app](#sample-app)

## Features

* 🚀 Over-the-air localization updates via the LingoHub CDN
* 🛡 Transactional installs — a corrupt download, full disk, or crash mid-update never breaks active translations
* 🔄 Runtime language switching, persisted across launches
* 📱 Works with `.strings`, `.stringsdict`, and String Catalog (`.xcstrings`) projects
* 🛠 Seamless integration — keep using `NSLocalizedString(...)` as usual, from any thread
* ⚡ Closure and async/await APIs
* 🔒 Descriptive error reporting with structured error codes
* 🕵️ Ships a privacy manifest (`PrivacyInfo.xcprivacy`)
* 📝 Optional debug logging

## How it works

1. Publish a release for a **Distribution** in LingoHub.
2. The SDK asks the LingoHub CDN whether a release matching your app version is available. Releases can target app version ranges, with an optional fallback release for all other versions.
3. If there is a new release, the SDK downloads it and serves the updated strings through the standard localization APIs (when swizzling is enabled).
4. Downloaded translations are cached on disk and discarded automatically when your app version changes, so a fresh app release always starts from its bundled strings.

If nothing has been published yet for your app version and environment, the SDK simply reports that no update is available — that is a normal state, not an error.

## Requirements

* iOS 15.0+ / macOS 12.0+
* Swift 5.9+ / Xcode 15+

> The SwiftUI snippets below use the two-parameter `onChange(of:)`, which requires iOS 17. On iOS 15–16, use the single-parameter variant as noted.

## Installation

The SDK is available via Swift Package Manager. In Xcode: **File → Add Package Dependencies…** and enter:

```
https://github.com/lingohub/ios-cdn-sdk.git
```

Or add it to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/lingohub/ios-cdn-sdk.git", from: "2.0.0")
]
```

> **Upgrading from 1.x?** Most integrations that use the documented API (`configure`, `swizzleMainBundle`, `update`/`updateAsync`, `setLanguage`) compile unchanged. What changed in 2.0:
>
> * **Platforms** — the minimum is now iOS 15 / macOS 12.
> * **1.0.0 type names removed** — the deprecated aliases `LingohubSDK`, `LingohubSDKError`, and `.LingohubDidUpdateLocalization` are gone; use the LingoHub spelling (`LingoHubSDK`, `LingoHubSDKError`, `.LingoHubDidUpdateLocalization`). The module name is unchanged (`import Lingohub`).
> * **Internalized symbols** — `checkForUpdate(result:)`, `downloadUpdate(...)`, `useUpdatedBundle(...)`, `updateBundleExists`, `BundleInfo`, and `HTTPMethod` were implementation details and are no longer public. `update(result:)` / `updateAsync()` cover the complete cycle.
> * **`language` setter** — assigning the property now behaves exactly like `setLanguage(_:)` / `setSystemLanguage()`: the override is persisted, `nil` removes it.
> * Coming from **1.0.0**: also see the 1.1.0 notes in the [changelog](CHANGELOG.md) (`.apiError` gained an `errorCodes` associated value).
>
> Downloaded translations and settings migrate automatically; no user-visible state is lost.

## Get your API key

1. In LingoHub, open your project and create a **Distribution** (type: *Mobile SDK iOS*).
2. Publish a release for the environment you want to use (or mark one release as the fallback).
3. Copy the distribution's CDN API key — it starts with `lh-cdn_`.

See the [LingoHub CDN documentation](https://developers.lingohub.com/reference/distributions) for details.

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
        LingoHubSDK.shared.configure(withApiKey: "lh-cdn_...")

        // Enable method swizzling for automatic localization
        LingoHubSDK.shared.swizzleMainBundle()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                // Check for updates when the app becomes active
                LingoHubSDK.shared.update()
            }
        }
    }
}
```

> Note: the SDK exports its own `Environment` type, so the SwiftUI property wrapper needs to be written as `@SwiftUI.Environment`.
>
> On iOS 15–16, use the single-parameter `onChange`: `.onChange(of: scenePhase) { newPhase in ... }`

### UIKit

```swift
import Lingohub

func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    // Configure the SDK with your CDN API key
    LingoHubSDK.shared.configure(withApiKey: "lh-cdn_...")

    // Enable method swizzling for automatic localization
    LingoHubSDK.shared.swizzleMainBundle()

    return true
}

func applicationDidBecomeActive(_ application: UIApplication) {
    // Check for updates when the app becomes active
    LingoHubSDK.shared.update()
}
```

### Use your strings as usual

With swizzling enabled, keep using `NSLocalizedString` — the SDK serves the updated translation when one is available and falls back to your bundled strings otherwise:

```swift
NSLocalizedString("welcome_message", comment: "Welcome message")
```

Swizzling is what routes lookups through LingoHub. Without `swizzleMainBundle()`, your app keeps showing the strings packaged in the app bundle — downloaded translations are never applied (unless you use the [manual API](#manual-localization)). Once enabled, swizzling stays active for the lifetime of the process; there is no API to disable it at runtime. While no downloaded release is active, swizzled lookups take the original code path unchanged.

#### File formats

* **`.strings`** — fully supported.
* **`.stringsdict`** (plurals) — supported through the swizzled `NSLocalizedString` path.
* **String Catalogs (`.xcstrings`)** — supported. Xcode compiles String Catalogs into `.strings`/`.stringsdict` at build time, so the swizzled lookup works unchanged. LingoHub delivers the updated files in the same compiled formats.

## Configuration

```swift
LingoHubSDK.shared.configure(
    withApiKey: "lh-cdn_...",
    environment: .production, // optional, defaults to .production
    logLevel: .full           // optional, defaults to .none
)
```

| Parameter     | Values                                                | Default                                           |
| ------------- | ----------------------------------------------------- | ------------------------------------------------- |
| `appVersion`  | Any version string, used for release targeting        | `CFBundleShortVersionString` from your Info.plist |
| `environment` | `.production`, `.staging`, `.development`, `.test`    | `.production`                                     |
| `logLevel`    | `.none`, `.full`                                      | `.none`                                           |

The `environment` must match the environment of the release you published. The `appVersion` matters because releases in LingoHub can target app version ranges. Enable `.full` logging only in debug builds:

```swift
#if DEBUG
let logLevel: LogLevel = .full
#else
let logLevel: LogLevel = .none
#endif
```

## Advanced Usage

### Switch languages at runtime

```swift
// Override with an ISO 639-1 language code
LingoHubSDK.shared.setLanguage("de")

// Back to the system language
LingoHubSDK.shared.setSystemLanguage()
```

The override applies to LingoHub-served strings, is persisted, and is restored on the next launch. Already-rendered views don't re-render themselves — drive a refresh from your UI, for example:

```swift
struct ContentView: View {
    @State private var refreshTrigger = false

    var body: some View {
        VStack {
            Text(NSLocalizedString("welcome_message", comment: ""))
            Button("Deutsch") {
                LingoHubSDK.shared.setLanguage("de")
                refreshTrigger.toggle()
            }
        }
        .id(refreshTrigger) // re-render on language change
    }
}
```

`LingoHubSDK.shared.currentLanguageCode` returns the language currently being served (the override, or the system language when none is set) — use it to initialize that state. `LingoHubSDK.shared.language` is the override only and is `nil` when the SDK follows the system language; assigning it behaves exactly like calling `setLanguage(_:)` (persisted) or, with `nil`, `setSystemLanguage()`.

### Manual localization

If you prefer not to use method swizzling:

```swift
func getLocalizedString(for key: String, tableName: String? = nil) -> String {
    if let localizedString = LingoHubSDK.shared.localizedString(forKey: key, tableName: tableName) {
        return localizedString
    }
    return NSLocalizedString(key, tableName: tableName, comment: "")
}
```

The manual API reads `.strings` files only; `.stringsdict` plurals need the swizzled path.

### Update notifications

Via `NotificationCenter` — posted after a new translation bundle has been downloaded and is fully active. Strings read from an observer (even one running synchronously) already resolve against the new release:

```swift
NotificationCenter.default.addObserver(
    forName: .LingoHubDidUpdateLocalization,
    object: nil,
    queue: .main
) { [weak self] _ in
    self?.updateUI()
}
```

Via callback — `true` means new translations were downloaded and are active, `false` means there was nothing new:

```swift
LingoHubSDK.shared.update { result in
    switch result {
    case .success(let updated):
        if updated {
            // new translations are active, refresh your UI if needed
        }
    case .failure(let error):
        print("LingoHub update failed: \(error.localizedDescription)")
    }
}
```

Callbacks are delivered on the main queue. Concurrent `update()`/`updateAsync()` calls (for example, a manual refresh racing a foreground-transition check) share a single update cycle — one network request, one install — and every caller receives the same result.

Or with async/await:

```swift
do {
    let updated = try await LingoHubSDK.shared.updateAsync()
    if updated {
        // new translations are active, refresh your UI if needed
    }
} catch {
    print("LingoHub update failed: \(error.localizedDescription)")
}
```

### Reduce network requests

`update()` performs a network request each time it is called, and CDN usage counts towards your plan. If you don't need instant updates, check only periodically — for example once a day:

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
        LingoHubSDK.shared.update { result in
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

Two situations are **not** errors and are reported as `.success(false)` — "no new content":

* **Already up to date** — the CDN answered that you have the latest release.
* **Nothing published yet** — no release exists for your environment and app version (`DISTRIBUTION_NOT_FOUND`). Publish a release in your Distribution to resolve this.

Real failures are delivered as `LingoHubSDKError`. The `.apiError` case carries the HTTP status and the server's error codes as structured fields — `statusCode: Int` and `errorCodes: [String]` — so you can react without parsing the message:

| Status | Error codes                                                             | Meaning and what to do                                                                                                                  |
| ------ | ----------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| 401    | `CDN_KEY_NOT_FOUND`, `CDN_KEY_EXPIRED`, `TOKEN_EXPIRED`, `JWT_INVALID`  | The API key is missing, invalid, revoked, or rotated — check the key you pass to `configure`                                             |
| 429    | `USAGE_LIMIT_EXCEEDED`                                                  | Your CDN usage budget is exhausted; the SDK pauses further checks for an hour. Consider throttling your own checks (see "Reduce network requests") |
| 400    | —                                                                       | Malformed request — usually an SDK/backend version mismatch, please report it                                                            |
| other  | —                                                                       | Network errors and unexpected responses                                                                                                  |

```swift
LingoHubSDK.shared.update { result in
    switch result {
    case .success(let updated):
        print(updated ? "Translations updated" : "Already up to date")
    case .failure(let error):
        switch error {
        case .apiError(429, _, _):
            scheduleRetryTomorrow()
        case .apiError(_, _, let errorCodes) where errorCodes.contains("CDN_KEY_EXPIRED"):
            alertKeyRotationNeeded()
        case .invalidApiKey:
            print("API key is missing — call configure first")
        default:
            print("LingoHub update failed: \(error.localizedDescription)")
        }
    }
}
```

`statusCode` is `0` for local and network errors (no response was received). `.invalidApiKey`, `.invalidAppVersion`, and `.invalidSdkVersion` mean `configure` was not called or was called with incomplete data. The CDN may introduce additional error codes over time — treat the table above as non-exhaustive.

### Troubleshooting

* **`update` keeps reporting `false` and nothing changes** — most likely no release is published yet for your app version and environment. Publish a release in your Distribution (or mark one as the fallback), and double-check that the `environment` you configure matches the release's environment. Enable `logLevel: .full` in a debug build to see what the SDK is doing.
* **Strings never change, not even after an app restart** — swizzling is not enabled. Call `LingoHubSDK.shared.swizzleMainBundle()` right after `configure`; see [Quick Start](#quick-start).
* **Strings change only after navigating away and back** — swizzling is in place, but visible views are not re-rendered when the update arrives. Observe `.LingoHubDidUpdateLocalization` and refresh your UI.
* **Error 401** — the CDN key is missing, invalid, or was revoked. `errorCodes` contains the reason (for example `CDN_KEY_NOT_FOUND`).
* **Error 429** — your CDN usage budget is exhausted. The SDK pauses checks for an hour; throttle your own checks too.

## Privacy

The SDK includes a `PrivacyInfo.xcprivacy` manifest, which Xcode merges into your app's privacy report automatically — relevant for your App Store privacy declarations. What the SDK touches:

* `UserDefaults` — stores the installed release ID, the app version it was downloaded for, the language override, and the retry-pause expiry after a 429 response.
* Downloaded translation bundles — stored in the app's Application Support directory, excluded from device backups (they are re-downloadable).
* Each update check sends to the LingoHub CDN over HTTPS: your CDN API key (Authorization header), the configured environment and distribution type, your app's version, the currently served language, the currently installed release ID, the SDK version, and a random installation identifier (a UUID generated by the SDK and stored in the keychain) as the client identifier for usage metering. The identifier is not linked to user identity and not used for tracking, and it is declared in the bundled privacy manifest.

## Sample app

The [DemoAppLingoHub](DemoAppLingoHub/) project in this repository shows a complete SwiftUI integration, including runtime language switching and update notifications. Open it in Xcode, insert your CDN API key in [LingohubApp.swift](DemoAppLingoHub/DemoAppLingoHub/LingohubApp.swift), and run.

## Support

For bug reports and feature requests, please open an issue on GitHub.

## License

Apache License Version 2.0, January 2004. More info in the [LICENSE](./LICENSE) file.

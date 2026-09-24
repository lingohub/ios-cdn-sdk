# LingoHub iOS SDK

[![Release](https://img.shields.io/github/v/release/lingohub/ios-cdn-sdk?style=flat-square)](https://github.com/lingohub/ios-cdn-sdk/releases)
[![License](https://img.shields.io/github/license/lingohub/ios-cdn-sdk?style=flat-square)](./LICENSE)
[![Platform](https://img.shields.io/badge/platform-iOS%2015%2B-blue?style=flat-square)](#requirements)

A Swift SDK for over-the-air (OTA) localization with [LingoHub](https://lingohub.com). Update your app's translations without releasing a new app version.

**Contents:** [How it works](#how-it-works) · [Installation](#installation) · [Get your API key](#get-your-api-key) · [Quick Start](#quick-start) · [Which lookup APIs are covered](#which-lookup-apis-are-covered) · [Configuration](#configuration) · [Advanced Usage](#advanced-usage) · [Error handling](#error-handling) · [Privacy](#privacy) · [Sample app](#sample-app)

## Features

* 🚀 Over-the-air localization updates via the LingoHub CDN
* 🛡 Transactional installs — a corrupt download, full disk, or crash mid-update never breaks active translations
* 🔄 Runtime language switching, persisted across launches
* 🧩 SwiftUI and Swift lookups via `Bundle.lingohub`: `Text("key", bundle: .lingohub)`, `String(localized:bundle:)`, `LocalizedStringResource`
* 🛠 `NSLocalizedString`, storyboards, and XIBs via swizzling — keep your code as it is, from any thread
* 📱 `.strings`, `.stringsdict` (plurals), and String Catalog (`.xcstrings`) projects — what decides coverage is the [lookup API](#which-lookup-apis-are-covered), not the file format
* ⚡ Closure and async/await APIs
* 🔒 Descriptive error reporting with structured error codes
* 🕵️ Ships a privacy manifest (`PrivacyInfo.xcprivacy`)
* 📝 Optional debug logging

## How it works

1. Publish a release for a **Distribution** in LingoHub.
2. The SDK asks the LingoHub CDN whether a release matching your app version is available. Releases can target app version ranges, with an optional fallback release for all other versions.
3. If there is a new release, the SDK downloads it and serves the updated strings: to `NSLocalizedString`, storyboards, and XIBs through swizzling, and to SwiftUI `Text`, `String(localized:)`, and `LocalizedStringResource` through [`Bundle.lingohub`](#swift-and-swiftui-bundlelingohub).
4. Downloaded translations are cached on disk and discarded automatically when your app version changes, so a fresh app release always starts from its bundled strings.

If nothing has been published yet for your app version and environment, the SDK simply reports that no update is available — that is a normal state, not an error.

## Requirements

* iOS 15.0+ / macOS 12.0+
* Swift 5.9+ / Xcode 15+

> The SwiftUI snippets below use the two-parameter `onChange(of:)`, which requires iOS 17. On iOS 15–16, use the single-parameter variant as noted. The `LocalizedStringResource` helpers (`Text(lh:)`, `String(lh:)`, `resolve(_:)`) require iOS 16 / macOS 13.

## Installation

The SDK is available via Swift Package Manager. In Xcode: **File → Add Package Dependencies…** and enter:

```
https://github.com/lingohub/ios-cdn-sdk.git
```

Or add it to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/lingohub/ios-cdn-sdk.git", from: "2.1.0")
]
```

> **Using SwiftUI or `String(localized:)`?** Before 2.1 these lookups never showed downloaded translations — swizzling cannot reach them, although earlier versions of this README suggested otherwise. Pass `bundle: .lingohub`; see [Which lookup APIs are covered](#which-lookup-apis-are-covered).

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

        // Only needed if parts of your app use NSLocalizedString, storyboards, or XIBs
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

struct ContentView: View {
    @State private var refreshID = UUID()
    @State private var unreadCount = 3

    var body: some View {
        VStack {
            // Look strings up in the LingoHub bundle
            Text("welcome_message", bundle: .lingohub)
            Text("\(unreadCount) unread messages", bundle: .lingohub)
        }
        .id(refreshID)
        // Re-render when new translations are active
        .onReceive(NotificationCenter.default.publisher(for: .LingoHubDidUpdateLocalization)) { _ in
            refreshID = UUID()
        }
    }
}
```

SwiftUI's `Text("key")`, `String(localized:)`, and `LocalizedStringResource` look strings up without calling `Bundle.localizedString(forKey:value:table:)`, the one method `swizzleMainBundle()` intercepts — without `bundle: .lingohub` they always show the strings bundled with your app. `Bundle.lingohub` serves the downloaded release and falls back to your bundled strings for keys the release doesn't contain. `Text(NSLocalizedString("welcome_message", comment: ""))` works too (it goes through the swizzled method, which is what SDK versions before 2.1 required), but renders the string verbatim, without markdown, and needs `String(format:)` for arguments. More in [Which lookup APIs are covered](#which-lookup-apis-are-covered).

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

## Which lookup APIs are covered

The SDK serves downloaded translations along two paths. Which one a string takes depends on the API you look it up with, not on the file format:

| Lookup | Shows downloaded translations | How |
| ------ | ----------------------------- | --- |
| `NSLocalizedString` (Swift and Objective-C), `Bundle.localizedString(forKey:value:table:)` | ✅ | `swizzleMainBundle()` |
| Storyboards and XIBs localized with `.strings` files (Base Internationalization) | ✅ | `swizzleMainBundle()` |
| SwiftUI `Text("key", bundle: .lingohub)` | ✅ | `Bundle.lingohub` |
| `String(localized: "key", bundle: .lingohub)`, `AttributedString(localized: "key", bundle: .lingohub)` | ✅ | `Bundle.lingohub` |
| `LocalizedStringResource`, through `Text(lh:)`, `String(lh:)`, `LingoHubSDK.shared.resolve(_:)`, or `bundle: .atURL(Bundle.lingohub.bundleURL)` | ✅ | `Bundle.lingohub` (iOS 16+) |
| `String(localized:)`, `AttributedString(localized:)`, `LocalizedStringResource`, SwiftUI `Text("key")` — without the LingoHub bundle | ❌ bundled strings only | — |
| SwiftUI initializers that take a `LocalizedStringKey` but no bundle: `Button("key")`, `Label("key", …)`, `Toggle("key", …)`, `.navigationTitle("key")`, … | ❌ bundled strings only | pass a `Text(…, bundle: .lingohub)` or `LingoHubSDK.shared.resolve("key")` instead |

The ❌ rows look strings up without ever calling `Bundle.localizedString(forKey:value:table:)`, and Foundation offers no public way to intercept them. Hooking the private methods they use instead would put your app's review at risk and break with OS updates, so the SDK does not — use `Bundle.lingohub`.

### `NSLocalizedString`, storyboards, and XIBs: swizzling

With swizzling enabled, keep using `NSLocalizedString` — the SDK serves the updated translation when one is available and falls back to your bundled strings otherwise:

```swift
NSLocalizedString("welcome_message", comment: "Welcome message")
```

Swizzling is what routes these lookups through LingoHub. Without `swizzleMainBundle()`, they keep showing the strings packaged in the app bundle — downloaded translations are never applied (unless you use the [manual API](#manual-localization)). Once enabled, swizzling stays active for the lifetime of the process; there is no API to disable it at runtime. While no downloaded release is active, swizzled lookups take the original code path unchanged.

### Swift and SwiftUI: `Bundle.lingohub`

Pass `Bundle.lingohub` wherever a Swift API takes a bundle:

```swift
Text("welcome_message", bundle: .lingohub)
Text("\(count) new messages", bundle: .lingohub)                  // .stringsdict plurals
String(localized: "welcome_message", bundle: .lingohub)
AttributedString(localized: "terms_markdown", bundle: .lingohub)
```

`LocalizedStringResource` has no `Bundle` parameter; use the helpers (iOS 16+):

```swift
Text(lh: "welcome_message")
let status = String(lh: "\(count) new messages")
Button(LingoHubSDK.shared.resolve("save_button")) { save() }
LocalizedStringResource("welcome_message", bundle: .atURL(Bundle.lingohub.bundleURL))
```

All of these keep Xcode extracting your strings into the String Catalog. How `Bundle.lingohub` behaves:

* When a release is activated, the SDK writes a merged bundle next to it: every string table of your app bundle with the release's entries laid over it. Keys the release doesn't contain resolve to your bundled strings, `.stringsdict` plurals included.
* A language set with `setLanguage(_:)` is served whatever locale a lookup carries. Languages that only exist in the release fall back to your development language for keys it lacks.
* Without an active release — before the first download, or after an app update discarded it — `Bundle.lingohub` is `Bundle.main`.
* It covers your app bundle. Strings of frameworks or Swift packages (`bundle: .module`) keep reading their own bundle.
* Read it where you look a string up (for example in `body`) instead of storing it: it changes when a release is activated or the language switches. Refresh visible views on [`.LingoHubDidUpdateLocalization`](#update-notifications).

`Text(lh:)`, `String(lh:)`, and `resolve(_:)` keep a resource's key, table, default value, locale, and interpolation arguments. Because `LocalizedStringResource.bundle` is read-only, they rebuild the resource through its `Codable` representation — Apple's format, not a documented contract. That makes them best effort: should an OS release change the format, the resource is returned unchanged and shows your bundled strings. `Text("key", bundle: .lingohub)` and `String(localized:bundle:)` don't depend on it.

### File formats

* **`.strings`** and **`.stringsdict`** (plurals, device variations) — served on both paths.
* **String Catalogs (`.xcstrings`)** — Xcode compiles them into `.strings`/`.stringsdict` at build time, and LingoHub delivers releases in the same compiled formats, so the file format needs no extra support. Whether a string shows downloaded translations depends on the lookup API — see the table above. String Catalog projects typically use SwiftUI and `String(localized:)`, which need `Bundle.lingohub`.

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

The override is persisted and restored on the next launch. It applies to LingoHub-served strings, so it takes effect once a release is active: `Bundle.lingohub` then serves the override language entirely (your bundled strings in that language for keys the release lacks), while swizzled lookups serve the release's strings in that language and fall back to the system language for keys it lacks. Already-rendered views don't re-render themselves — drive a refresh from your UI, for example:

```swift
struct ContentView: View {
    @State private var refreshTrigger = false

    var body: some View {
        VStack {
            Text("welcome_message", bundle: .lingohub)
            Button {
                LingoHubSDK.shared.setLanguage("de")
                refreshTrigger.toggle()
            } label: {
                Text("switch_to_german", bundle: .lingohub)
            }
        }
        .id(refreshTrigger) // re-render on language change
    }
}
```

`LingoHubSDK.shared.currentLanguageCode` returns the language currently being served (the override, or the system language when none is set) — use it to initialize that state. `LingoHubSDK.shared.language` is the override only and is `nil` when the SDK follows the system language; assigning it behaves exactly like calling `setLanguage(_:)` (persisted) or, with `nil`, `setSystemLanguage()`.

#### Plurals with a language override

`.stringsdict` patterns select their plural category at *format* time, from the formatting locale (a Foundation behavior, independent of this SDK). Without an override that matches automatically — the device language and the served strings agree. If you override to a language whose plural rules differ from the device language (say, `setLanguage("ru")` on an English device), format with the override's locale:

```swift
let locale = Locale(identifier: LingoHubSDK.shared.currentLanguageCode ?? "en")

// NSLocalizedString: instead of String.localizedStringWithFormat
let pattern = NSLocalizedString("apples_count", comment: "")
let text = String(format: pattern, locale: locale, count)

// Swift
let label = String(localized: "\(count) apples", bundle: .lingohub, locale: locale)

// SwiftUI
Text("\(count) apples", bundle: .lingohub)
    .environment(\.locale, locale)
```

Languages sharing the simple one/other rule (English, German, Spanish, …) are unaffected either way.

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

The manual API reads `.strings` files only; for `.stringsdict` plurals use the swizzled path or [`Bundle.lingohub`](#swift-and-swiftui-bundlelingohub).

### Update notifications

Via `NotificationCenter` — posted after a new translation bundle has been downloaded and is fully active. Strings read from an observer (even one running synchronously) already resolve against the new release, through swizzling and `Bundle.lingohub` alike. It is also posted when translations downloaded earlier become available to `Bundle.lingohub` shortly after launch (the first launch with SDK 2.1, or of a new app build whose bundled strings changed):

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

Cancelling a task that awaits `updateAsync()` never aborts the shared cycle (other callers may be waiting on it); the cancelled caller throws `CancellationError` no later than when the cycle finishes.

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
* **SwiftUI `Text("key")` or `String(localized:)` never shows downloaded translations** — these lookups never reach swizzling. Pass `bundle: .lingohub`, or use `Text(lh:)` / `String(lh:)`; see [Which lookup APIs are covered](#which-lookup-apis-are-covered).
* **`Button("key")`, `Label`, or `.navigationTitle("key")` don't change** — these SwiftUI initializers take no bundle. Use a `Text("key", bundle: .lingohub)` label, or pass `LingoHubSDK.shared.resolve("key")`.
* **`NSLocalizedString` strings never change, not even after an app restart** — swizzling is not enabled. Call `LingoHubSDK.shared.swizzleMainBundle()` right after `configure`; see [Quick Start](#quick-start).
* **Strings change only after navigating away and back** — lookups are served, but visible views are not re-rendered when the update arrives. Observe `.LingoHubDidUpdateLocalization` and refresh your UI.
* **Error 401** — the CDN key is missing, invalid, or was revoked. `errorCodes` contains the reason (for example `CDN_KEY_NOT_FOUND`).
* **Error 429** — your CDN usage budget is exhausted. The SDK pauses checks for an hour; throttle your own checks too.

## Privacy

The SDK includes a `PrivacyInfo.xcprivacy` manifest, which Xcode merges into your app's privacy report automatically — relevant for your App Store privacy declarations. What the SDK touches:

* `UserDefaults` — stores the installed release ID, the app version it was downloaded for, the name of the folder the release is stored in, the language override, and the retry-pause expiry after a 429 response.
* Downloaded translation bundles, and the merged copy of your app's string tables that `Bundle.lingohub` serves — stored in the app's Application Support directory, excluded from device backups (they are re-downloadable or rebuilt).
* Each update check sends to the LingoHub CDN over HTTPS: your CDN API key (Authorization header), the configured environment and distribution type, your app's version, the currently served language, the currently installed release ID, the SDK version, and a random installation identifier (a UUID generated by the SDK and stored in the keychain) as the client identifier for usage metering. The identifier is not linked to user identity and not used for tracking, and it is declared in the bundled privacy manifest.

## Sample app

The [DemoAppLingoHub](DemoAppLingoHub/) project in this repository shows a complete SwiftUI integration with `Bundle.lingohub` and `Text(lh:)`, including runtime language switching and update notifications. Open it in Xcode, insert your CDN API key in [LingohubApp.swift](DemoAppLingoHub/DemoAppLingoHub/LingohubApp.swift), and run.

## Support

For bug reports and feature requests, please open an issue on GitHub.

## License

Apache License Version 2.0, January 2004. More info in the [LICENSE](./LICENSE) file.

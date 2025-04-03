# Lingohub iOS SDK

A Swift SDK for integrating Lingohub's over-the-air localization services in iOS applications. This SDK allows you to update your app's localizations without requiring a new app release.

## Features

* 🚀 Over-The-Air (OTA) localization updates
* 🔄 Runtime language switching
* 📱 Support for `.strings` and `.stringsdict` files
* 🛠 Method swizzling for seamless integration
* 🔒 Robust error handling
* 📝 Optional debug logging

## Requirements

* iOS 14.0+

## Installation

### Swift Package Manager

Add the following dependency to your `Package.swift` file:

```swift
dependencies: [
    .package(url: "https://github.com/lingohub/ios-cdn-sdk.git", from: "1.0.0")
]
```

Or add it directly in Xcode via File > Add Packages > "https://github.com/lingohub/ios-cdn-sdk.git"

## Quick Start

### 1. Import the SDK

```swift
import Lingohub
```

### 2. Configure the SDK

Swift UI: Initialize in your main `App`:

```swift
@main
struct YourApp: App {
    @SwiftUI.Environment(\.scenePhase) private var scenePhase

    init() {
        // Configure the SDK with your API key
        LingohubSDK.shared.configure(
            withApiKey: "YOUR-API-KEY",
        )

        // Enable method swizzling for automatic localization
        LingohubSDK.shared.swizzleMainBundle()
    }

    //...
}
```

For UIKit Initialize the SDK in your `AppDelegate` or `SceneDelegate`:

```swift
func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    // Configure the SDK with your API key
    LingohubSDK.shared.configure(
        withApiKey: "YOUR-API-KEY",
    )

    // Enable method swizzling for automatic localization
    LingohubSDK.shared.swizzleMainBundle()

    return true
}
```

### 3. Check for Updates

For Swift UI add the following code to you main `App` file:

```swift
  var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            if newPhase == .active {
                // Check for updates when app becomes active
                LingohubSDK.shared.update()
            }
        }
  }
```


For UIKit add the following code where appropriate (e.g., when your app becomes active):

```swift
func applicationDidBecomeActive(_ application: UIApplication) {
    Task {
        LingohubSDK.shared.update()
    }
}
```


## 4. Usage

Use NSLocalizedString as usual, LingohubSDK will take care of the rest:

```swift
NSLocalizedString("id", comment: "description of string")
```

## Advanced Usage


Initialize the Lingohub SDK with optional parameters:

| Parameter | Example Value | Description | Default |
|-----------|--------------|-------------|----------|
| appVersion | "1.0.0" | The version of your app | Value from Info.plist |
| environment | .production | Environment to use (.production, .staging, .development, .test) | .production |
| logLevel | .none | Control debug logging output (.none or .full) | .none |


```swift
@main
struct YourApp: App {
    @SwiftUI.Environment(\.scenePhase) private var scenePhase

    init() {
        // Configure the SDK with your API key
        LingohubSDK.shared.configure(
            withApiKey: "YOUR-API-KEY",
            environment: .production,
            logLevel: .full // Enable detailed logging (not recommmended for production)
        )

        // Enable method swizzling for automatic localization
        LingohubSDK.shared.swizzleMainBundle()
    }

    //...
}
```

### Switch Languages

Change the app's language at runtime:

```swift
// Set to a specific language
LingohubSDK.shared.setLanguage("de")
```


Same optional parameters for UIKit in your `AppDelegate` or `SceneDelegate`:

```swift
func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    // Configure the SDK with your API key
    LingohubSDK.shared.configure(
        withApiKey: "YOUR-API-KEY",
        environment: .production,
        logLevel: .full // Enable detailed logging (not recommmended for production)
    )

    // Enable method swizzling for automatic localization
    LingohubSDK.shared.swizzleMainBundle()

    return true
}
```


### Manual Localization

If you prefer not to use method swizzling:

```swift
func getLocalizedString(for key: String, tableName: String? = nil) -> String {
    if let localizedString = LingohubSDK.shared.localizedString(forKey: key, tableName: tableName) {
        return localizedString
    }
    return NSLocalizedString(key, tableName: tableName, comment: "")
}
```

### Update Notifications

Get notified of localization updates via Observer:

```swift
NotificationCenter.default.addObserver(
    forName: .LingohubDidUpdateLocalization,
    object: nil,
    queue: .main
) { [weak self] _ in
    self?.updateUI()
}
```

Get notified via callback

```swift
LingohubSDK.shared.update { result in
    switch result {
    case .success(let value):
        if value {
            cacheManager.updateLastFetchTime()
       }
    }
}
```

### Environments

Available environments:

- **Production** (`.production`): The default environment for released apps
- **Development** (`.development`): For development and testing
- **Staging** (`.staging`): For pre-production testing
- **Test** (`.test`): For running automated tests

## Error Handling

The SDK provides detailed error information through `LingohubSDKError`:

```swift
LingohubSDK.shared.update { result in
    switch result {
    case .success(let updated):
        // Handle successful update
    case .failure(let error as LingohubSDKError):
        switch error {
        case .invalidApiKey:
            print("API key is missing")
        case .invalidAppVersion:
            print("App version is missing")
        case .invalidSdkVersion:
            print("SDK version is missing")
        case .apiError(let statusCode, let message):
            print("API error: \(statusCode), \(message ?? "No message")")
        case .unknown:
            print("Unknown error occurred")
        }
    }
}
```


### Optimizing Network Requests with CacheManager

Optional caching is possible to reduce network requests, you can implement a simple CacheManager:

```swift
import Foundation

class CacheManager {
    private let userDefaults = UserDefaults.standard
    private let lastFetchKey = "last_fetch_time"
    private let oneDayInSeconds: TimeInterval = 24 * 60 * 60

    func shouldFetchStrings() -> Bool {
        let lastFetchTime = userDefaults.double(forKey: lastFetchKey)
        let currentTime = Date().timeIntervalSince1970
        return currentTime - lastFetchTime >= oneDayInSeconds
    }

    func updateLastFetchTime() {
        let currentTime = Date().timeIntervalSince1970
        userDefaults.set(currentTime, forKey: lastFetchKey)
    }
}
```

Then use it when checking for updates:

```swift
@main
struct YourApp: App {
    @SwiftUI.Environment(\.scenePhase) private var scenePhase
    private let cacheManager = CacheManager()

    // ... existing init code ...

    var body: some Scene {
        WindowGroup {
            //SwiftUI View
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            if newPhase == .active {
                // Only fetch if needed
                if cacheManager.shouldFetchStrings() {
                    LingohubSDK.shared.update { result in
                        switch result {
                        case .success(let value):
                            if value {
                                cacheManager.updateLastFetchTime()
                            }
                        }
                    }
                }
            }
        }
    }
}
```


## Support

For bug reports and feature requests, please open an issue on GitHub.

## License

Apache License Version 2.0, January 2004. More infos in the `LICENSE` file.
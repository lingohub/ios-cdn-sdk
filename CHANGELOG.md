# Changelog

All notable changes to this project will be documented in this file.

## [2.0.0] - 2026-09-01

2.0 is a reliability release: translation updates now install transactionally — a corrupt download, a full disk, or a crash mid-install can never break the translations your users are seeing — and all heavy work moved off the main thread. The public API was reduced to the surface that was always documented.

### Breaking
- Minimum platforms raised to **iOS 15** and **macOS 12** (enables the native async `URLSession` APIs the rewritten networking uses).
- The deprecated 1.0.0 type aliases (`LingohubSDK`, `LingohubSDKError`, `.LingohubDidUpdateLocalization`) are removed. Use the LingoHub-spelled names introduced in 1.1.0. `import Lingohub`, persisted keys, and storage locations are unchanged; downloaded translations survive the upgrade.
- Implementation details that were unintentionally public are now internal: `checkForUpdate(result:)`, `downloadUpdate(...)`, `useUpdatedBundle(...)`, `updateBundleExists`, `BundleInfo`, and `HTTPMethod`. Use `update(result:)` / `updateAsync()` — both drive the complete check → download → install cycle.
- Setting the `language` property now behaves exactly like `setLanguage(_:)` / `setSystemLanguage()`: a non-nil value is persisted, `nil` removes the persisted override. (Previously the setter changed the served language without persisting it.)

### Changed
- Release installation is transactional: archives are extracted into a staging directory, validated against the exact layout runtime lookup resolves (`.lproj` directories at the release root; every `.strings` must parse as `[String: String]`, every `.stringsdict` as a dictionary plist — the same contracts the loaders apply), then activated with an atomic filesystem swap. At every point in time the installed bundle is either the complete previous release or the complete new one. The common "zipped a folder" shape (a single wrapper directory containing the `.lproj` folders) is normalized automatically.
- `configure` heals leftovers from interrupted installs: stale staging directories are removed, metadata pointing at a missing or unusable bundle is cleared, and an unreferenced bundle is deleted.
- Extraction, validation, and checksum hashing run off the main thread; installing an update no longer blocks animations or input.
- Concurrent `update()`/`updateAsync()` calls share a single in-flight cycle — one network round-trip, one install, the same result for every caller. Closure callbacks are always delivered on the main queue. The shared cycle is never aborted by a caller's cancellation; a cancelled `updateAsync()` caller throws `CancellationError` no later than when the cycle finishes (documented on the API).
- Download hardening: release archives are rejected when oversized (50 MB compressed — enforced while bytes arrive, aborting the transfer; 200 MB uncompressed; 10,000 entries), when containing unsafe entry paths or symlinks, or when failing checksum verification. Non-HTTPS download URLs are refused, and redirects to non-HTTPS targets are refused mid-transfer. Presigned download URLs are logged with their query string (credentials) stripped.
- Localization lookups got cheaper: the active release is an immutable in-memory snapshot, so the hot path no longer checks the filesystem or reads UserDefaults on every `NSLocalizedString` call; per-language bundles are cached; log messages are only constructed when logging is enabled.

### Fixed
- `language` honors its documented contract again: it stays `nil` after `configure` unless an override was set. (1.x populated it with the system language on configure, making "override" and "system default" indistinguishable.)
- The update notification is posted only after the new release is fully active, so observers that read localized strings synchronously always see the new translations. (Previously they could read the previous release's cached values.)
- A caller-supplied `value:` fallback no longer shadows the app bundle's own translation when a key is missing from the downloaded release.
- A malformed 200 response without a download URL now surfaces as a decoding error instead of being silently patched over (`BundleInfo` decodes strictly; the unused `createdAt` field was dropped).
- The demo app no longer accumulates notification observers on repeated appearances, and it demonstrates the README's update-throttling guidance.

### Added
- Archive integrity verification: when the CDN response includes `filesSha256`, the downloaded archive is verified against it before installation.
- CI: the test suite now also runs on an iOS simulator; a public-API diff job flags breaking changes on pull requests; a non-blocking Swift 6 language-mode job tracks the ZIPFoundation migration.

### Internal
- `APIClient` rewritten with async/await behind an injectable `APIClientProtocol`; downloaded files are moved instead of copied.
- 25 new tests (57 total): corrupt/malformed/oversized archives each preserving the previous release, crash healing, update coalescing, notification ordering, lookup consistency while releases are swapped, and checksum verification.

## [1.1.0] - 2026-09-01

### Changed (naming)
- The public API was renamed to the LingoHub brand spelling: `LingoHubSDK`, `LingoHubSDKError`, and `.LingoHubDidUpdateLocalization`. Deprecated aliases for the 1.0.0 type names are included for Swift and for the Objective-C `NSNotification` accessor, so they keep compiling with warnings. The module name (`import Lingohub`), persisted keys, storage folder, and the notification's raw value are unchanged; file, folder, and build-target names keep the historical spelling to avoid project churn.

### Added
- async/await variant of the update check: `try await LingoHubSDK.shared.updateAsync()`. Named distinctly so existing fire-and-forget `update()` calls in async contexts keep compiling unchanged.
- `LingoHubSDKError.apiError` now carries the CDN's structured error codes as a third associated value (`errorCodes: [String]`, e.g. `CDN_KEY_NOT_FOUND`, `USAGE_LIMIT_EXCEEDED`), matching the Android SDK, so apps can react programmatically without parsing the message. **Source change required** for existing `.apiError` pattern matches and constructions: add a third pattern or `errorCodes: []` — see the migration note in the README.
- `currentLanguageCode`: the language the SDK is currently serving (the override, or the system language when none is set). The `language` property remains the override only and is `nil` when following the system language.
- The language override set via `setLanguage(_:)` is now persisted and restored on the next launch. `setSystemLanguage()` removes it. (The previous implementation wrote to an ineffective defaults key and lost the override on relaunch.)
- After an HTTP 429 (CDN usage budget exhausted), the SDK pauses further update checks for one hour instead of retrying on every call.
- `PrivacyInfo.xcprivacy` privacy manifest (required-reason APIs: UserDefaults CA92.1, file attributes C617.1; anonymous installation identifier declared, no tracking). Xcode merges it into the app's privacy report automatically.
- CI workflow: build and test on macOS, build for the iOS Simulator.
- This changelog.

### Changed
- The swizzled `Bundle.localizedString(forKey:value:table:)` path is now genuinely thread-safe: shared localization state moved into a lock-protected store, matching the documented thread-safety of `NSLocalizedString`. This also removes the false main-actor annotation that would have turned into runtime crashes under Swift 6 language mode.
- Downloaded translation bundles moved from `Documents/Lingohub` (visible in the Files app with file sharing enabled, included in backups) to Application Support, excluded from backups. Existing installs are migrated automatically.
- The keychain installation identifier is now stored under the SDK's own service (`com.lingohub.sdk`) with `kSecAttrAccessibleAfterFirstUnlock`, instead of a generic un-namespaced item. Identifiers written by SDK 1.0.x are adopted automatically.
- Transport failures before a response is received (offline, DNS, timeout) and local request/response failures are now reported as `.apiError(statusCode: 0, ...)` per the documented contract, instead of `.unknown`.
- README rewritten to mirror the [LingoHub Android SDK](https://github.com/lingohub/android-cdn-sdk): all snippets compile, documents where the CDN API key comes from (keys start with `lh-cdn_`), file-format notes (`.stringsdict`, String Catalogs), an error-code table with remediation advice, troubleshooting, and a complete privacy/data-flow disclosure.
- Demo app references the SDK by local path instead of a pinned remote revision, so it always runs against the checked-out code.

### Fixed
- Parse the CDN's current RFC 7807 error responses (`detail` + `errors[].infos`), so API errors carry a meaningful message again. The legacy `error_message` format is still supported as a fallback.
- Send the client language as `clientLanguageCode` (the field the CDN reads); previously the value was sent under a name the API ignores. The effective language is reported: the `setLanguage(_:)` override when set, otherwise the system language - matching lookup behavior.
- Treat the CDN's 404 `DISTRIBUTION_NOT_FOUND` response from the update check (no release matches the app version and no fallback release exists, e.g. nothing published yet) as "no update available" instead of an error. Other 404s remain failures.
- Report the real SDK version to the CDN. Previously the host app's version was sent, because `Bundle(for:)` resolves to the app bundle under SwiftPM.
- `Package.swift` declared macOS 10.15, but `os.Logger` requires macOS 11 — the package failed to compile for macOS (including `swift build`/`swift test`). Now declares macOS 11.
- `swizzleBundle(_:)` now adds to the set of swizzled bundles instead of replacing it; swizzling a second bundle no longer un-registers the first.
- The downloaded update archive is deleted after extraction instead of accumulating in the temporary directory.
- Replaced the deprecated `Locale.current.languageCode` API.
- User-facing error descriptions: fixed "occured" typos.

### Removed
- Dead code: unused `APIClientProtocol`, unused constants, an empty test, an unused test `Info.plist`, and committed `xcuserdata` files.

## [1.0.0] - 2025-04-03

Initial release.

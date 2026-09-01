# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Fixed
- Parse the CDN's current RFC 7807 error responses (`detail` + `errors[].infos`), so API errors carry a meaningful message again. The legacy `error_message` format is still supported as a fallback.
- Send the client language as `clientLanguageCode` (the field the CDN reads); previously the value was sent under a name the API ignores. The language override set via `setLanguage(_:)` is now reported instead of always the system locale.
- Treat HTTP 404 from the update check (no release matches the app version and no fallback release exists, e.g. nothing published yet) as "no update available" instead of an error.
- Report the real SDK version to the CDN. Previously the host app's version was sent, because `Bundle(for:)` resolves to the app bundle under SwiftPM.
- `Package.swift` declared macOS 10.15, but `os.Logger` requires macOS 11 — the package failed to compile for macOS (including `swift build`/`swift test`). Now declares macOS 11.
- `swizzleBundle(_:)` now adds to the set of swizzled bundles instead of replacing it; swizzling a second bundle no longer un-registers the first.
- The downloaded update archive is deleted after extraction instead of accumulating in the temporary directory.
- Replaced the deprecated `Locale.current.languageCode` API.
- User-facing error descriptions: fixed "occured" typos.

### Added
- `PrivacyInfo.xcprivacy` privacy manifest (required-reason APIs: UserDefaults CA92.1, file attributes C617.1; anonymous installation identifier declared, no tracking). Xcode merges it into the app's privacy report automatically.
- CI workflow: build and test on macOS, build for the iOS Simulator.
- This changelog.

### Changed
- README rewritten: all snippets compile now, documented where the CDN API key comes from, file-format notes (`.stringsdict`, String Catalogs), troubleshooting, and privacy details.
- Demo app references the SDK by local path instead of a pinned remote revision, so it always runs against the checked-out code.

### Removed
- Dead code: unused `APIClientProtocol`, unused constants, an empty test, an unused test `Info.plist`, and committed `xcuserdata` files.

## [1.0.0] - 2025-04-03

Initial release.

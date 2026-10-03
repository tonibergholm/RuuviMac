# Validation — October 3, 2026

Environment: Apple Silicon Mac, Apple Swift 6.4, Xcode beta macOS 27 SDK;
project deployment minimum macOS 13, Swift tools 5.9, Swift 5 language mode.

- `swift test --build-system native`: 5 XCTest tests passed, zero failures.
- Official RAWv2 valid/minimum/maximum/unavailable vectors passed.
- All truncated lengths, wrong company ID, and unsupported format rejected.
- History sequence deduplication, 24-hour retention, and saved name/favorite
  archive round trips passed.
- Release executable and sandboxed ad-hoc signed `.app` built successfully.
- Clean app ZIP extracted to a temporary folder passed
  `codesign --verify --deep --strict`.
- App launched through Launch Services and its process remained running.

The synced Documents folder injects Finder metadata into `.app` directories.
Packaging signs and verifies in a temporary staging directory, then makes an
archive without extended attributes. Swift 6.4's default swiftbuild signing also
encountered this metadata; validation used its native build-system option.
Upstream BTKit emits Swift 6.4 weak-capture warnings; there are no project build
errors. The two documented macOS platform guards fix unavailable API calls.

No physical RuuviTag was used during validation. Bluetooth permission outcomes,
live radio discovery/readings, suspend/wake, and comparison with Ruuvi Station
remain hardware smoke tests. Older macOS versions and Intel builds were not
executed here. The provided prebuilt app is arm64; build from source for Intel.

# Validation — October 3, 2026

Environment: Apple Silicon Mac, Apple Swift 6.4, Xcode beta macOS 27 SDK;
project deployment minimum macOS 13, Swift tools 5.9, Swift 5 language mode.

- `swift test --build-system native`: 10 XCTest tests passed, zero failures.
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

## MQTT v0.2

- Real loopback MQTT broker: Gateway RAWv2 and RuuviBridge decoded JSON were
  received by the actual MQTTNIO transport; pressure conversion and publisher
  timestamps passed. Parsing, malformed JSON, status packets, future/nonfinite
  timestamps, boolean fields and topic validation are covered.
- Passwords are session-only; TLS uses system certificate verification.
  Authentication/TLS against a production broker were not exercised.
- This version pins MQTTNIO and its Swift dependencies in Package.resolved.
  The tests and app build used the installed Swift 6.4 toolchain.

## Icon v0.2.1

- Xcode 27 Icon Composer / actool compiled the original vector-layer design.
- Native generation-27 default, dark and monochrome renders were inspected.
- Build includes the compiled layered Assets.car and legacy AppIcon.icns,
  referenced by CFBundleIconName and CFBundleIconFile.
- The checked-in ICNS preserves an icon when building with older Xcode.
  Older Xcode and macOS releases were not run for this icon change.
- Release app rebuilt and clean ZIP passed strict signature verification.
- On macOS 27.0.1, NSWorkspace resolved the bundled sensor icon successfully.

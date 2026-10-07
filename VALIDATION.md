# Validation — October 3, 2026

Environment: Apple Silicon Mac, Apple Swift 6.4, Xcode 27.0 release macOS 27 SDK;
project deployment minimum macOS 13, Swift tools 5.9, Swift 5 language mode.

- `swift test --build-system native`: 10 XCTest tests passed, zero failures.
- Official RAWv2 valid/minimum/maximum/unavailable vectors passed.
- All truncated lengths, wrong company ID, and unsupported format rejected.
- History sequence deduplication, retention, and saved name/favorite
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

Initial v0.1 validation did not use a physical tag. Subsequent native app checks
received live readings from a nearby RuuviTag. Suspend/wake and comparison with
Ruuvi Station remain hardware smoke tests. Older macOS versions and Intel builds were not
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

## Tag history v0.3

- All 13 tests passed, including the real MQTT broker test. Official log-read
  request framing, negative temperature and pressure units, missing values,
  partial/out-of-order fields and duplicate imports are covered.
- Imports preserve the latest reading, last-seen time, names and favorites;
  local history retains ten days and supports both chart periods.
- Release app built using Xcode 27.0 (27A266a), Swift 6.4 and SDK 27.
- The native download button completed a real RuuviTag transfer: 1,644 stored
  samples received and 1,558 new samples imported alongside existing history.
  The saved archive had 1,702 samples with all three environmental fields;
  relaunch showed the downloaded history and preserved the name/favorite.
- Early connection timeouts were followed by a successful transfer after the
  user released an iOS connection to the tag. Live scanning resumed afterward.
  No firmware or tag data was changed.
- Connectable-advertisement checks now give guidance when the tag broadcasts
  without accepting connections. Only one app should connect to a tag at once.

## Background and menu bar v0.4

- `swift test --build-system native`: 22 tests executed, 1 skipped (the real
  MQTT broker test, which needs `RUUVI_MQTT_TEST_PORT`), zero failures.
- `swift --version`: Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1)
- `xcodebuild -version`: Xcode 27.0, build version 27A266a.
- `./scripts/build-app.sh` built `dist/RuuviMac.app` and the ZIP.

User smoke test on October 7, 2026, with a nearby RuuviTag, using the v0.5
build: the menu lists tags with temperature and humidity; closing the window
hides the Dock icon while the menu keeps updating; `open -a RuuviMac` restores
one window with the Dock icon; clicking a menu row selects the tag and Open
RuuviMac twice gives one window; quitting from the menu and relaunching keeps
the latest readings; enabling Open at login registered the app as enabled and
allowed (`sfltool dumpbtm`), with no approval prompt. Items 4 (logout and
login), 5 (sleep and wake), 6 (10 minutes windowless) and 9 (unreadable
archive) were not run. The list as planned:

1. Close the window. Dock icon gone, menu icon stays, menu readings update,
   history sample count rises after a few minutes.
2. Quit from the menu with the window closed. Relaunch. Latest reading present.
3. "Open RuuviMac…" restores the window and the Dock icon.
4. Enable open at login, log out and in, twice: once with "Reopen windows when
   logging back in" checked and once unchecked. App starts windowless and collects.
5. Sleep and wake. Scanning resumes and readings update.
6. Windowless for 10 minutes. `stat -f %m` on the archive shows saves continuing.
7. Clicking a tag row selects it in the window. "Open RuuviMac…" twice gives one window.
8. Close the window, then run `open -a RuuviMac` (or open it from Finder). The
   window, Dock icon and menu bar all return.
9. Replace a copy of `sensors.json` with `{not json`, launch, let readings
   arrive, quit. `shasum` of the file is unchanged. Skipped deliberately to
   avoid touching the real archive; run it on a copy and restore afterward.

Login item registration and the Login Items approval prompt have not been
observed on a real login.

## Home Assistant bridge v0.5

- `RUUVI_MQTT_TEST_PORT=18884 swift test --build-system native` against a
  local mosquitto 2.1.2 (127.0.0.1, anonymous): 47 tests executed, 2 skipped
  (the Keychain store tests), zero failures. The publisher loopback test then
  passed 5 more consecutive runs. It covers config before state, the retained
  config seen by a later subscriber, the birth message, the Last Will after an
  abrupt drop, reconnect, an acknowledged removal, and retained `offline` on
  ordered stop. The broker log showed both the abrupt close and the clean
  DISCONNECT. The existing real-broker MQTT input test also passed.
- Not covered by automation: the bridge controller (settings, Keychain,
  ownership), Home Assistant itself, and quit inside the running app.
- Keychain store tests (`RUUVI_KEYCHAIN_TESTS=1`): run once during Task 3,
  2 passed with no prompt. The test runner is unsandboxed, so the access
  behavior of the sandboxed ad-hoc signed app is untested. They were not
  rerun for this section.
- Accepted deviation: MQTTNIO 2.13.0 sends the Last Will at QoS 0 (retained).
- `swift --version`: Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1)
- `xcodebuild -version`: Xcode 27.0, build version 27A266a.
- `./scripts/build-app.sh` built `dist/RuuviMac.app` and the ZIP.

App check against the local mosquitto broker on October 7, 2026 (no Home
Assistant available): the running app was configured through the settings
sheet for 127.0.0.1:18884 without credentials. A topic watcher saw `online` on
`ruuvimac/<bridge>/status`, the tag's discovery config followed by its state,
an empty retained config after Remove from Home Assistant, and retained
`offline` with a clean disconnect on quit. Afterwards only the retained
`offline` remained, and the saved ledger had the tag switched off with no
pending removal. Not checked: Home Assistant's handling of the payloads, the
Keychain password path, and the items below.

Manual checks with a Home Assistant broker, not run (no Home Assistant available):

1. Settings: enable with the broker details. Status reaches "Connected to the
   Home Assistant broker". A wrong password shows the credentials message and
   keeps retrying. Pending user test.
2. Home Assistant shows one device per nearby tag with six entities; values
   match the app. Pending user test.
3. Rename a tag. The device name changes and no second device appears.
   Pending user test.
4. Restart Home Assistant. Devices and values return within about a minute.
   Pending user test.
5. Quit RuuviMac while connected. It quits within about 2 seconds, entities
   become unavailable, and relaunch shows the latest readings. Pending user test.
6. Turn off Wi-Fi or stop the broker, then restore it. Status shows retrying,
   then connected; values resume. Pending user test.
7. Turn off publishing for one tag. Its entities go unavailable after about
   ten minutes; the device stays. Pending user test.
8. Remove one tag while the broker is unreachable, then relaunch with the
   broker reachable. The device disappears. Pending user test.
9. Keychain across rebuilds, normal launch and login item: whether macOS
   prompts, what Always Allow does, what Deny plus Try again does, and that
   menu readings keep updating during an unanswered prompt. Pending user test.
10. Two bridges: use a second Mac, or launch a second copy with
    `open -n RuuviMac.app --args -ha.bridgeID 11111111` (it shares the ledger
    and sensor archive with the first copy). Quitting one must not mark the
    other's tags unavailable. Pending user test.

# RuuviMac

An independent, open-source native SwiftUI macOS MVP for nearby RuuviTags.

## Official app check — October 3, 2026

No official native macOS app was found. Ruuvi's [Station page](https://ruuvi.com/station/) advertises Android, iOS, and a cloud web app. The [official App Store listing](https://apps.apple.com/us/app/ruuvi-station/id1384475885?platform=mac) lists iPhone, iPad, and Apple Vision compatibility, with no Mac entry. This is a point-in-time finding, not a guarantee about future releases or every regional store. The web app is an existing option for Mac users with cloud-connected sensors.

## Features

- CoreBluetooth discovery with duplicate advertisements enabled; no pairing, internet account, or Gateway required.
- Official Ruuvi BTKit RAWv2 decoder, vendored from a pinned revision with documented macOS build guards.
- Live temperature (°C), humidity (%), pressure (hPa), battery voltage, acceleration, movement counter, TX power, and RSSI.
- Editable local names, favorites, and persisted devices; stale signal indicator after 30 seconds.
- Temperature/humidity/pressure charts for locally collected samples, at most one per minute, capped at 1,440 samples per sensor. Views show the last 24 hours.
- Bluetooth permission/off/reset states and visible storage errors.

## Build and run

Requires macOS 13+, a Bluetooth LE capable Mac, and Xcode 15+ or compatible Swift 5.9+ tools. Set Xcode's command-line tools in Xcode Settings → Locations if needed. BTKit is vendored, so builds need no external package downloads.

```sh
cd RuuviMac
swift test
./scripts/build-app.sh
open dist/RuuviMac.app
```

Launch the app bundle so macOS associates Bluetooth permission with its bundle identifier and usage description. Allow Bluetooth access when prompted. Place a RuuviTag using format 5 (RAWv2) nearby, select it in the sidebar, and watch readings update. The bundle is locally ad-hoc signed and sandboxed with Bluetooth entitlement. For distribution use your own Developer ID, signing identity and notarization; this is not a notarized release.

If Swift 6.4 reports Finder metadata during test signing in a synced folder, use `swift test --build-system native` (the packaging script selects this automatically where supported), or build in a non-synced folder.

For editing, open `Package.swift` in Xcode and select the RuuviMac executable scheme / My Mac. Use the bundled build script to produce the runnable app; a raw `swift run` executable is not the supported permission flow. This is a Swift Package project and does not require XcodeGen or CocoaPods.

## Data and behavior

Names, favorites, latest readings, and history are stored atomically in `~/Library/Containers/org.ruuvimac.app/Data/Library/Application Support/RuuviMac/sensors.json` when sandboxed (or `~/Library/Application Support/RuuviMac/sensors.json` without sandbox). Updates flush about every five seconds and at normal termination. A forced quit may lose the latest few seconds. A malformed archive is reported rather than silently ignored; move it aside to reset.

History records new measurement sequences at minute intervals while this Mac is awake and the app is scanning. Repeated transmissions are omitted. Retention is pruned on new samples; old offline samples may remain on disk, but are excluded from the 24-hour chart. Last readings remain visible after relaunch and show stale until rediscovered. Samples use Mac receipt timestamps, not tag clock timestamps.

RAWv2 carries a full sensor MAC used as identity. An unavailable MAC falls back to CoreBluetooth's local peripheral UUID, which can change if macOS resets Bluetooth identity. Pausing scanning keeps existing data visible. This app makes no BLE connection and does not change tag configuration.

## Official APIs, SDKs, and protocol research

- [BTKit](https://github.com/ruuvi/BTKit): official Swift library, BSD-3-Clause. Its Swift package declares macOS 10.15+ support. This app reuses `RuuviDecoderiOS.decodeAdvertisement` (the class name is historical; it builds on macOS), with explicit framing validation. Vendored revision: `586df101c9c4bed1cc2a703a3467d397d1137c20`.
- BTKit compatibility patch: both scanner implementations now return `false` for the extended-advertising feature query on macOS, where `CBCentralManager.supports` is unavailable. The decoder is unchanged. SwiftDocC plugin dependency and upstream test target and unused documentation/localization resources are omitted from the vendored manifest; original source and license are retained. See `Vendor/BTKit/UPSTREAM.md`.
- [RAWv2 / format 5](https://docs.ruuvi.com/communication/bluetooth-advertisements/data-format-5-rawv2): manufacturer ID 0x0499, on-air company bytes 99 04; 24-byte payload, big-endian fields and invalid-value sentinels. Official published test vectors cover valid, minimum, maximum, and unavailable data. BTKit returns pressure in hPa and acceleration in g.
- [Bluetooth protocol documentation](https://docs.ruuvi.com/communication/bluetooth-connection): Nordic UART Service provides heartbeat and logged-history transfers. BTKit also exposes log retrieval APIs. Sensor-memory history requires a connection, firmware compatibility, transfer handling, and hardware validation, so it is deferred.
- [Ruuvi Cloud OpenAPI](https://github.com/ruuvi/ruuvi.cloudapi.yaml): official cloud user API specifications. Cloud authentication and remote readings are deferred; no credentials are needed for this MVP.
- [Official iOS Station source](https://github.com/ruuvi/com.ruuvi.station.ios): full mobile reference application, BSD-3-Clause. No Station source or branding assets are copied here.
- [Format 6](https://docs.ruuvi.com/communication/bluetooth-advertisements/data-format-6), E1, C5, encrypted formats, and legacy Eddystone formats exist, but this MVP intentionally accepts only RuuviTag RAWv2. Ruuvi Air is outside this release.

## Validation and limitations

Run `swift test` for official protocol vectors, malformed/truncated/wrong-manufacturer packets, sentinel handling, history retention/deduplication, and archive round trips. The native executable and app bundle can be built locally. Real sensor discovery, permission prompts, range, suspend/wake behavior, and battery readings still require a physical RuuviTag smoke test; automated tests cannot establish radio interoperability.

Hardware smoke test: launch the bundle, grant Bluetooth, verify a nearby RAWv2 tag appears and readings agree with Ruuvi Station, rename/favorite it, wait for history samples, pause/resume, relaunch to check persistence, move it out of range, and toggle Bluetooth off/on. Also test denied permission recovery in System Settings.

No cloud sync, alarms, background launch service, sensor-memory download, CSV export, or firmware updates in v0.1. The app must stay running and the Mac awake to collect samples.

## Licensing

New project code is MIT licensed (`LICENSE`). Ruuvi's BTKit remains BSD-3-Clause; its notice is included in `Resources/BTKit-LICENSE.txt` and must accompany distributions. The packaging script includes this notice. Ruuvi names and trademarks belong to their owners. This project is independent and is not an official Ruuvi product.

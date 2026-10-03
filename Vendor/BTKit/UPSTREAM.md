# Vendored Ruuvi BTKit

Source: https://github.com/ruuvi/BTKit
Revision: 586df101c9c4bed1cc2a703a3467d397d1137c20
Retrieved: 2026-10-03
License: BSD-3-Clause; full upstream LICENSE retained.

Source changes: `BTScanneriOS.swift` and `BTBackgroundScanneriOS.swift` guard the
`CBCentralManager.supports(.extendedScanAndConnect)` query with `#if os(macOS)`
and return false on macOS. Apple marks that query unavailable for macOS in the
installed SDK. RAWv2 decoding does not depend on extended advertising.

Manifest changes: omit SwiftDocC dependency and upstream test target (upstream
tests were not vendored), and exclude documentation and unused localization
resources from the build. No source references `Bundle.module`. All Sources files are retained without other changes.
Upstream README is included for reference. Our app uses its own CoreBluetooth
scanner and only the official RAWv2 decoder; upstream scanner classes are unused.

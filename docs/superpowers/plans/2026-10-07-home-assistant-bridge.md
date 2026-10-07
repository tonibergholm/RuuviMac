# Home Assistant MQTT bridge implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** RuuviMac publishes the RuuviTags it hears over Bluetooth to a Home Assistant MQTT broker with device discovery, one owning Mac per tag, with the broker password in the Keychain.

**Architecture:** Pure, tested logic lives in `RuuviCore`: discovery topics and payloads, settings validation, a publish router (source filter, MAC check, ownership ledger with per-tag decisions, 60 second throttle) and a Keychain password store. `RuuviMQTT` gains a thin `HomeAssistantPublisher` (MQTTNIO client with Last Will, reconnect, birth subscription, acknowledged removals, ordered shutdown). `RuuviMac` gains a `HomeAssistantBridge` controller owned by the app delegate, a settings sheet and per-tag controls.

**Tech Stack:** Swift 5.9 tools, SwiftUI + AppKit (macOS 13+), MQTTNIO 2.13.0 (already pinned), Security framework, XCTest.

**Spec:** `docs/superpowers/specs/2026-10-07-home-assistant-bridge-design.md`

**Review:** revised after an independent Sol review (2026-10-07) that found compile errors, publisher replacement races, non-transactional password saves, unbounded shutdown, quit-time run-loop delivery, ignored publish failures and a racy loopback test.

**Base:** branch `feature/ha-bridge`, stacked on `feature/background-menubar` (PR #1). It uses PR #1's `AppDelegate`, `applicationShouldTerminate` hook, `MenuBarView` and `SelectionModel`.

## Global Constraints

- Deployment target stays macOS 13. No API newer than macOS 13 without `if #available`. Swift tools 5.9, Swift 5 mode.
- No new package dependencies. MQTTNIO stays at 2.13.0.
- Entitlements unchanged (sandbox, Bluetooth, network client). Network client covers outbound MQTT.
- Only Bluetooth-sourced readings from MAC-identified tags are published. MQTT-input readings are never published.
- Keychain: legacy file-based Keychain, `kSecClassGenericPassword`, service `org.ruuvimac.homeassistant`, account `username@host:port`, no `kSecUseDataProtectionKeychain`, no synchronization, default ACL. Keychain calls never run on the main queue.
- MQTT input passwords stay session-only.
- Topics and ids exactly as in the spec: availability `ruuvimac/<bridge>/status`, state `ruuvimac/<mac>/state`, config `<prefix>/device/ruuvi_<mac>/config`, birth `<prefix>/status`, device id `ruuvimac_<mac>`, entity ids `ruuvimac_<mac>_<field>`, `exp_aft` 600, throttle 60 seconds, bridge id 8 lowercase hex digits in `ha.bridgeID`.
- Config retained QoS 1. State not retained QoS 0. Availability retained QoS 1, Last Will retained `offline`. MQTTNIO 2.13.0 always sends the will at QoS 0; that deviation is accepted and documented.
- MQTT ACK waits are bounded with `timeout: .seconds(10)` in the client configuration (MQTTNIO's default is unbounded).
- Quit waits at most 2 seconds for the ordered shutdown. Quit-time completions run on the main run loop in common and modal-panel modes (`MainRunLoop`), never synchronously.
- `ha.hasPassword == false` means username-only or anonymous; the Keychain is read only when it is true.
- Build and test: `swift test --build-system native`, `./scripts/build-app.sh`. The loopback broker tests run only when `RUUVI_MQTT_TEST_PORT` is set; Keychain tests only when `RUUVI_KEYCHAIN_TESTS=1`.
- Prose in README, VALIDATION and commits: plain sentences, sentence-case headings, no em dashes.

## Review Focus

Not covered by unit tests; each has a manual or loopback check in Task 8.

1. A login launch where the Keychain prompts and nobody answers. Bluetooth collection, the menu and saves must keep working; the publisher waits.
2. Quit while connected to an unreachable or slow broker. The app must quit within about 2 seconds and the readings must be saved.
3. Settings changed while connected (host, prefix or credentials). The old connection is shut down in order before the new one starts, and there is never more than one live client.
4. Removal requested while offline, then the app restarts and connects. The removal is sent before any config for that broker and is cleared only after the broker acknowledges it.
5. A tag renamed in the app. Home Assistant shows the new device name without duplicating the device.

---

### Task 1: Discovery payloads and settings

**Files:**
- Create: `Sources/RuuviCore/HomeAssistantDiscovery.swift`
- Test: `Tests/RuuviCoreTests/HomeAssistantDiscoveryTests.swift`

**Interfaces:**
- Consumes: `MQTTMessageDecoder.mac(_:) -> String?` (normalizes to `AA:BB:CC:DD:EE:FF`), `MQTTSettings(host:port:topic:username:password:tls:).validationError`, `Reading`.
- Produces:
  - `public enum HomeAssistantDiscovery` with `static func macKey(_ id: String) -> String?`, `static func availabilityTopic(bridge: String) -> String`, `static func stateTopic(macKey: String) -> String`, `static func configTopic(prefix: String, macKey: String) -> String`, `static func birthTopic(prefix: String) -> String`, `static func config(macKey: String, name: String, bridge: String, version: String) -> Data`, `static func state(_ reading: Reading, rssi: Int) -> Data`, `static func prefixError(_ prefix: String) -> String?`, `static func newBridgeID() -> String`.
  - `public struct HomeAssistantSettings: Codable, Equatable` with `host`, `port`, `tls`, `username`, `prefix`, `publishNewTags`, `validationError: String?`, `account: String`, `brokerKey: String`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/RuuviCoreTests/HomeAssistantDiscoveryTests.swift`:

```swift
import XCTest
@testable import RuuviCore

final class HomeAssistantDiscoveryTests: XCTestCase {
    func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testMacKeyAcceptsMacsAndRejectsPeripheralUUIDs() {
        XCTAssertEqual(HomeAssistantDiscovery.macKey("C4:A1:B2:D3:E4:F5"), "c4a1b2d3e4f5")
        XCTAssertEqual(HomeAssistantDiscovery.macKey("c4a1b2d3e4f5"), "c4a1b2d3e4f5")
        XCTAssertNil(HomeAssistantDiscovery.macKey("E621E1F8-C36C-495A-93FC-0C247A3E6E5F"))
        XCTAssertNil(HomeAssistantDiscovery.macKey(""))
    }

    func testTopics() {
        XCTAssertEqual(HomeAssistantDiscovery.availabilityTopic(bridge: "0a1b2c3d"), "ruuvimac/0a1b2c3d/status")
        XCTAssertEqual(HomeAssistantDiscovery.stateTopic(macKey: "c4a1b2d3e4f5"), "ruuvimac/c4a1b2d3e4f5/state")
        XCTAssertEqual(HomeAssistantDiscovery.configTopic(prefix: "homeassistant", macKey: "c4a1b2d3e4f5"),
                       "homeassistant/device/ruuvi_c4a1b2d3e4f5/config")
        XCTAssertEqual(HomeAssistantDiscovery.birthTopic(prefix: "ha"), "ha/status")
    }

    func testConfigPayload() throws {
        let obj = try json(HomeAssistantDiscovery.config(macKey: "c4a1b2d3e4f5", name: "Sauna", bridge: "0a1b2c3d", version: "0.5.0"))
        let dev = try XCTUnwrap(obj["dev"] as? [String: Any])
        XCTAssertEqual(dev["ids"] as? [String], ["ruuvimac_c4a1b2d3e4f5"])
        XCTAssertEqual(dev["name"] as? String, "Sauna")
        XCTAssertEqual(dev["mf"] as? String, "Ruuvi")
        XCTAssertEqual(dev["mdl"] as? String, "RuuviTag")
        XCTAssertEqual(dev["cns"] as? [[String]], [["mac", "C4:A1:B2:D3:E4:F5"]])
        let origin = try XCTUnwrap(obj["o"] as? [String: Any])
        XCTAssertEqual(origin["name"] as? String, "RuuviMac")
        XCTAssertEqual(origin["sw"] as? String, "0.5.0")
        XCTAssertEqual(origin["url"] as? String, "https://github.com/tonibergholm/RuuviMac")
        XCTAssertEqual(obj["avty_t"] as? String, "ruuvimac/0a1b2c3d/status")
        XCTAssertEqual(obj["stat_t"] as? String, "ruuvimac/c4a1b2d3e4f5/state")
        let cmps = try XCTUnwrap(obj["cmps"] as? [String: [String: Any]])
        XCTAssertEqual(Set(cmps.keys), ["temperature", "humidity", "pressure", "voltage", "rssi", "movement"])
        let t = try XCTUnwrap(cmps["temperature"])
        XCTAssertEqual(t["p"] as? String, "sensor")
        XCTAssertEqual(t["unique_id"] as? String, "ruuvimac_c4a1b2d3e4f5_temperature")
        XCTAssertEqual(t["name"] as? String, "Temperature")
        XCTAssertEqual(t["dev_cla"] as? String, "temperature")
        XCTAssertEqual(t["stat_cla"] as? String, "measurement")
        XCTAssertEqual(t["unit_of_meas"] as? String, "°C")
        XCTAssertEqual(t["val_tpl"] as? String, "{{ value_json.temperature }}")
        XCTAssertEqual(t["exp_aft"] as? Int, 600)
        XCTAssertNil(t["ent_cat"])
        XCTAssertEqual(cmps["pressure"]?["dev_cla"] as? String, "atmospheric_pressure")
        XCTAssertEqual(cmps["pressure"]?["unit_of_meas"] as? String, "hPa")
        XCTAssertEqual(cmps["humidity"]?["unit_of_meas"] as? String, "%")
        XCTAssertEqual(cmps["voltage"]?["ent_cat"] as? String, "diagnostic")
        XCTAssertEqual(cmps["voltage"]?["unit_of_meas"] as? String, "V")
        XCTAssertEqual(cmps["rssi"]?["dev_cla"] as? String, "signal_strength")
        XCTAssertEqual(cmps["rssi"]?["unit_of_meas"] as? String, "dBm")
        XCTAssertEqual(cmps["movement"]?["ent_cat"] as? String, "diagnostic")
        XCTAssertNil(cmps["movement"]?["dev_cla"])
        XCTAssertNil(cmps["movement"]?["unit_of_meas"])
    }

    func testStatePayloadWithValuesAndNulls() throws {
        let full = Reading(date: Date(timeIntervalSince1970: 1_791_370_000), temperature: 21.4, humidity: 41.2,
                           pressure: 1003.1, voltage: 2.95, movement: 12)
        let obj = try json(HomeAssistantDiscovery.state(full, rssi: -71))
        XCTAssertEqual(obj["temperature"] as? Double, 21.4)
        XCTAssertEqual(obj["humidity"] as? Double, 41.2)
        XCTAssertEqual(obj["pressure"] as? Double, 1003.1)
        XCTAssertEqual(obj["voltage"] as? Double, 2.95)
        XCTAssertEqual(obj["rssi"] as? Int, -71)
        XCTAssertEqual(obj["movement"] as? Int, 12)
        XCTAssertEqual(obj["ts"] as? Int, 1_791_370_000)
        let empty = try json(HomeAssistantDiscovery.state(Reading(date: Date(timeIntervalSince1970: 5), temperature: .nan), rssi: -80))
        for key in ["temperature", "humidity", "pressure", "voltage", "movement"] {
            XCTAssertTrue(empty[key] is NSNull, key)
        }
    }

    func testPrefixAndSettingsValidation() {
        XCTAssertNil(HomeAssistantDiscovery.prefixError("homeassistant"))
        XCTAssertNil(HomeAssistantDiscovery.prefixError("ha/discovery"))
        for bad in ["", "/ha", "ha/", "ha/#", "ha/+/x", "a\0b"] { XCTAssertNotNil(HomeAssistantDiscovery.prefixError(bad), bad) }
        var s = HomeAssistantSettings(host: "ha.local")
        XCTAssertNil(s.validationError)
        XCTAssertEqual(s.port, 1883)
        XCTAssertEqual(s.prefix, "homeassistant")
        XCTAssertTrue(s.publishNewTags)
        s.port = 0
        XCTAssertNotNil(s.validationError)
        s = HomeAssistantSettings(host: "mqtt://ha.local")
        XCTAssertNotNil(s.validationError)
        s = HomeAssistantSettings(host: "ha.local", prefix: "#")
        XCTAssertNotNil(s.validationError)
        let named = HomeAssistantSettings(host: "ha.local", port: 8883, username: "ruuvi")
        XCTAssertEqual(named.account, "ruuvi@ha.local:8883")
        XCTAssertEqual(named.brokerKey, "ha.local:8883/homeassistant")
    }

    func testBridgeID() {
        let id = HomeAssistantDiscovery.newBridgeID()
        XCTAssertEqual(id.count, 8)
        XCTAssertTrue(id.allSatisfy { "0123456789abcdef".contains($0) })
    }
}
```

- [ ] **Step 2: Run and see it fail**

Run: `swift test --build-system native --filter HomeAssistantDiscoveryTests`
Expected: compile failure, `cannot find 'HomeAssistantDiscovery' in scope`.

- [ ] **Step 3: Implement**

Create `Sources/RuuviCore/HomeAssistantDiscovery.swift`:

```swift
import Foundation

/// Home Assistant MQTT device discovery: topics, ids and payloads. No networking.
public enum HomeAssistantDiscovery {
    /// Lowercase MAC without separators, or nil for ids that are not MACs (the CoreBluetooth UUID fallback).
    public static func macKey(_ id: String) -> String? {
        MQTTMessageDecoder.mac(id).map { $0.replacingOccurrences(of: ":", with: "").lowercased() }
    }
    public static func availabilityTopic(bridge: String) -> String { "ruuvimac/\(bridge)/status" }
    public static func stateTopic(macKey: String) -> String { "ruuvimac/\(macKey)/state" }
    public static func configTopic(prefix: String, macKey: String) -> String { "\(prefix)/device/ruuvi_\(macKey)/config" }
    public static func birthTopic(prefix: String) -> String { "\(prefix)/status" }

    private struct Field {
        let key: String, name: String, deviceClass: String?, unit: String?, diagnostic: Bool
    }
    private static let fields = [
        Field(key: "temperature", name: "Temperature", deviceClass: "temperature", unit: "°C", diagnostic: false),
        Field(key: "humidity", name: "Humidity", deviceClass: "humidity", unit: "%", diagnostic: false),
        Field(key: "pressure", name: "Pressure", deviceClass: "atmospheric_pressure", unit: "hPa", diagnostic: false),
        Field(key: "voltage", name: "Battery voltage", deviceClass: "voltage", unit: "V", diagnostic: true),
        Field(key: "rssi", name: "Signal strength", deviceClass: "signal_strength", unit: "dBm", diagnostic: true),
        Field(key: "movement", name: "Movement counter", deviceClass: nil, unit: nil, diagnostic: true)
    ]

    public static func config(macKey: String, name: String, bridge: String, version: String) -> Data {
        var components: [String: Any] = [:]
        for field in fields {
            var c: [String: Any] = ["p": "sensor", "unique_id": "ruuvimac_\(macKey)_\(field.key)", "name": field.name,
                                    "stat_cla": "measurement", "val_tpl": "{{ value_json.\(field.key) }}", "exp_aft": 600]
            if let deviceClass = field.deviceClass { c["dev_cla"] = deviceClass }
            if let unit = field.unit { c["unit_of_meas"] = unit }
            if field.diagnostic { c["ent_cat"] = "diagnostic" }
            components[field.key] = c
        }
        let mac = MQTTMessageDecoder.mac(macKey) ?? macKey
        let object: [String: Any] = [
            "dev": ["ids": ["ruuvimac_\(macKey)"], "name": name, "mf": "Ruuvi", "mdl": "RuuviTag", "cns": [["mac", mac]]],
            "o": ["name": "RuuviMac", "sw": version, "url": "https://github.com/tonibergholm/RuuviMac"],
            "avty_t": availabilityTopic(bridge: bridge),
            "stat_t": stateTopic(macKey: macKey),
            "cmps": components
        ]
        return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    public static func state(_ reading: Reading, rssi: Int) -> Data {
        func number(_ value: Double?) -> Any { value.flatMap { $0.isFinite ? $0 : nil } ?? NSNull() }
        let object: [String: Any] = [
            "temperature": number(reading.temperature), "humidity": number(reading.humidity),
            "pressure": number(reading.pressure), "voltage": number(reading.voltage),
            "rssi": rssi, "movement": reading.movement.map { $0 as Any } ?? NSNull(),
            "ts": Int(reading.date.timeIntervalSince1970)
        ]
        return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    public static func prefixError(_ prefix: String) -> String? {
        if prefix.isEmpty || prefix.hasPrefix("/") || prefix.hasSuffix("/") || prefix.contains("+")
            || prefix.contains("#") || prefix.contains("\0") {
            return "Enter a discovery prefix without + or #, and without a leading or trailing /."
        }
        return nil
    }

    public static func newBridgeID() -> String {
        String(format: "%08x", UInt32.random(in: .min ... .max))
    }
}

public struct HomeAssistantSettings: Codable, Equatable {
    public var host: String
    public var port: Int
    public var tls: Bool
    public var username: String
    public var prefix: String
    public var publishNewTags: Bool
    public init(host: String, port: Int = 1883, tls: Bool = false, username: String = "",
                prefix: String = "homeassistant", publishNewTags: Bool = true) {
        self.host = host; self.port = port; self.tls = tls; self.username = username
        self.prefix = prefix; self.publishNewTags = publishNewTags
    }
    public var validationError: String? {
        MQTTSettings(host: host, port: port, tls: tls).validationError ?? HomeAssistantDiscovery.prefixError(prefix)
    }
    /// Keychain account for the broker password.
    public var account: String { "\(username)@\(host):\(port)" }
    /// Identifies the broker and prefix that retained configs were published to.
    public var brokerKey: String { "\(host):\(port)/\(prefix)" }
}
```

- [ ] **Step 4: Run and see it pass**

Run: `swift test --build-system native --filter HomeAssistantDiscoveryTests`
Expected: 6 tests pass.

- [ ] **Step 5: Full suite, commit**

Run: `swift test --build-system native` (all pass, broker test skipped).

```bash
git add Sources/RuuviCore/HomeAssistantDiscovery.swift Tests/RuuviCoreTests/HomeAssistantDiscoveryTests.swift
git commit -m "Add Home Assistant discovery topics, payloads and settings"
```

---

### Task 2: Ownership ledger and publish router

**Files:**
- Create: `Sources/RuuviCore/HomeAssistantRouting.swift`
- Test: `Tests/RuuviCoreTests/HomeAssistantRoutingTests.swift`

**Interfaces:**
- Consumes: `HomeAssistantDiscovery.macKey`, `HomeAssistantSettings` (Task 1).
- Produces:
  - `public enum ReadingSource { case bluetooth, mqtt }`
  - `public struct PendingRemoval: Codable, Hashable { macKey, host, port, prefix; var brokerKey: String }`
  - `public struct HomeAssistantLedger: Codable, Equatable` with `decisions: [String: Bool]`, `published: [String: Set<String>]`, `isPublishing(_:publishNewTags:)`, `isRemovalPending(_:)`, `adopt(_:publishNewTags:) -> Bool`, `setPublishing(_:_:)`, `markPublished(_:brokerKey:) -> Bool`, `queueRemoval(_:settings:) -> PendingRemoval`, `queueRemoveAll(settings:) -> [PendingRemoval]`, `pendingRemovals(for:) -> [PendingRemoval]`, `completeRemoval(_:)`.
  - `public struct PublishThrottle` with `init(interval: TimeInterval = 60)`, `shouldPublish(_:now:) -> Bool`, `resetAll()`, `reset(_:)`.
  - `public struct HomeAssistantRouter` with `var throttle`, `mutating func route(id: String, source: ReadingSource, connected: Bool, ledger: inout HomeAssistantLedger, publishNewTags: Bool, now: Date) -> String?`.

Ownership rule: a tag's publish decision is recorded the first time this Mac hears it while publishing is enabled (`adopt`), using the "Publish newly discovered tags" setting at that moment. Changing that setting later affects only tags not yet seen. "Remove all" covers tags this broker has from this Mac and that this Mac still publishes; tags handed to another Mac (switched off here) are left alone.

- [ ] **Step 1: Write the failing tests**

Create `Tests/RuuviCoreTests/HomeAssistantRoutingTests.swift`:

```swift
import XCTest
@testable import RuuviCore

final class HomeAssistantRoutingTests: XCTestCase {
    let mac = "C4:A1:B2:D3:E4:F5", key = "c4a1b2d3e4f5"
    let t0 = Date(timeIntervalSince1970: 1_000)
    let settings = HomeAssistantSettings(host: "ha.local")

    func testThrottle() {
        var throttle = PublishThrottle()
        XCTAssertTrue(throttle.shouldPublish(key, now: t0))
        XCTAssertTrue(throttle.shouldPublish("other", now: t0))
        XCTAssertFalse(throttle.shouldPublish(key, now: t0.addingTimeInterval(59)))
        XCTAssertTrue(throttle.shouldPublish(key, now: t0.addingTimeInterval(60)))
        throttle.reset(key)
        XCTAssertTrue(throttle.shouldPublish(key, now: t0.addingTimeInterval(61)))
        XCTAssertFalse(throttle.shouldPublish("other", now: t0.addingTimeInterval(30)), "reset of one tag must not reset others")
        throttle.resetAll()
        XCTAssertTrue(throttle.shouldPublish(key, now: t0.addingTimeInterval(62)))
        XCTAssertTrue(throttle.shouldPublish("other", now: t0.addingTimeInterval(62)))
    }

    func testRouterFiltersSourceIdentityConnectionAndOwnership() {
        var router = HomeAssistantRouter()
        var ledger = HomeAssistantLedger()
        XCTAssertNil(router.route(id: mac, source: .mqtt, connected: true, ledger: &ledger, publishNewTags: true, now: t0))
        XCTAssertNil(ledger.decisions[key], "MQTT readings must not adopt tags")
        XCTAssertNil(router.route(id: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F", source: .bluetooth, connected: true, ledger: &ledger, publishNewTags: true, now: t0))
        XCTAssertNil(router.route(id: mac, source: .bluetooth, connected: false, ledger: &ledger, publishNewTags: true, now: t0))
        XCTAssertEqual(ledger.decisions[key], true, "first Bluetooth sighting records the default")
        // A disconnected attempt must not consume the throttle.
        XCTAssertEqual(router.route(id: mac, source: .bluetooth, connected: true, ledger: &ledger, publishNewTags: true, now: t0), key)
        XCTAssertNil(router.route(id: mac, source: .bluetooth, connected: true, ledger: &ledger, publishNewTags: true, now: t0.addingTimeInterval(10)))
        ledger.setPublishing(key, false)
        router.throttle.resetAll()
        XCTAssertNil(router.route(id: mac, source: .bluetooth, connected: true, ledger: &ledger, publishNewTags: true, now: t0.addingTimeInterval(100)))
    }

    func testPendingRemovalBlocksRouting() {
        var router = HomeAssistantRouter()
        var ledger = HomeAssistantLedger()
        ledger.queueRemoval(key, settings: settings)
        ledger.setPublishing(key, true)
        XCTAssertNil(router.route(id: mac, source: .bluetooth, connected: true, ledger: &ledger, publishNewTags: true, now: t0))
    }

    func testDecisionIsRecordedOnceAndNotRetroactive() {
        var ledger = HomeAssistantLedger()
        XCTAssertTrue(ledger.adopt(key, publishNewTags: false))
        XCTAssertFalse(ledger.adopt(key, publishNewTags: true))
        XCTAssertFalse(ledger.isPublishing(key, publishNewTags: true), "turning the default on must not flip a recorded tag")
        ledger.setPublishing(key, true)
        XCTAssertTrue(ledger.isPublishing(key, publishNewTags: false))
        XCTAssertTrue(ledger.isPublishing("aaaaaaaaaaaa", publishNewTags: true), "unseen tags follow the default")
        XCTAssertFalse(ledger.isPublishing("aaaaaaaaaaaa", publishNewTags: false))
    }

    func testRemovalLifecycle() throws {
        var ledger = HomeAssistantLedger()
        ledger.adopt(key, publishNewTags: true)
        XCTAssertTrue(ledger.markPublished(key, brokerKey: settings.brokerKey))
        XCTAssertFalse(ledger.markPublished(key, brokerKey: settings.brokerKey))
        let removal = ledger.queueRemoval(key, settings: settings)
        XCTAssertEqual(removal, PendingRemoval(macKey: key, host: "ha.local", port: 1883, prefix: "homeassistant"))
        XCTAssertTrue(ledger.isRemovalPending(key))
        XCTAssertFalse(ledger.isPublishing(key, publishNewTags: true))
        XCTAssertEqual(ledger.queueRemoval(key, settings: settings), removal)
        XCTAssertEqual(ledger.pendingRemovals(for: settings), [removal])
        XCTAssertEqual(ledger.pendingRemovals(for: HomeAssistantSettings(host: "other.local")), [])
        XCTAssertEqual(ledger.pendingRemovals(for: HomeAssistantSettings(host: "ha.local", prefix: "ha")), [])
        let restored = try JSONDecoder().decode(HomeAssistantLedger.self, from: JSONEncoder().encode(ledger))
        XCTAssertEqual(restored.pendingRemovals(for: settings), [removal])
        ledger.completeRemoval(removal)
        XCTAssertFalse(ledger.isRemovalPending(key))
        XCTAssertEqual(ledger.pendingRemovals(for: settings), [])
        XCTAssertNil(ledger.published[settings.brokerKey]?.first)
        XCTAssertFalse(ledger.isPublishing(key, publishNewTags: true))
    }

    func testRemoveAllCoversOnlyOwnedTagsOnThisBroker() {
        var ledger = HomeAssistantLedger()
        for k in ["aaaaaaaaaaaa", "bbbbbbbbbbbb", "dddddddddddd"] {
            ledger.adopt(k, publishNewTags: true); ledger.markPublished(k, brokerKey: settings.brokerKey)
        }
        ledger.setPublishing("dddddddddddd", false)   // handed to another Mac
        ledger.adopt("cccccccccccc", publishNewTags: true)
        ledger.markPublished("cccccccccccc", brokerKey: HomeAssistantSettings(host: "other.local").brokerKey)
        let queued = ledger.queueRemoveAll(settings: settings)
        XCTAssertEqual(queued.map(\.macKey), ["aaaaaaaaaaaa", "bbbbbbbbbbbb"])
        XCTAssertTrue(ledger.isPublishing("cccccccccccc", publishNewTags: true))
        XCTAssertFalse(ledger.isRemovalPending("dddddddddddd"))
    }
}
```

- [ ] **Step 2: Run and see it fail**

Run: `swift test --build-system native --filter HomeAssistantRoutingTests`
Expected: compile failure, `cannot find 'PublishThrottle' in scope`.

- [ ] **Step 3: Implement**

Create `Sources/RuuviCore/HomeAssistantRouting.swift`:

```swift
import Foundation

public enum ReadingSource { case bluetooth, mqtt }

/// A deletion of a tag's retained discovery config, kept until the broker acknowledges it.
public struct PendingRemoval: Codable, Hashable {
    public let macKey: String
    public let host: String
    public let port: Int
    public let prefix: String
    public init(macKey: String, host: String, port: Int, prefix: String) {
        self.macKey = macKey; self.host = host; self.port = port; self.prefix = prefix
    }
    public var brokerKey: String { "\(host):\(port)/\(prefix)" }
}

/// Which tags this Mac publishes, where it published them, and removals not yet acknowledged.
public struct HomeAssistantLedger: Codable, Equatable {
    /// Per-tag choice for this Mac. Absent means not seen yet; the default setting applies.
    public private(set) var decisions: [String: Bool] = [:]
    public private(set) var published: [String: Set<String>] = [:]
    public private(set) var pending: [PendingRemoval] = []
    public init() {}

    public func isRemovalPending(_ macKey: String) -> Bool { pending.contains { $0.macKey == macKey } }
    public func isPublishing(_ macKey: String, publishNewTags: Bool) -> Bool {
        !isRemovalPending(macKey) && (decisions[macKey] ?? publishNewTags)
    }
    /// Records the default the first time a tag is seen. Returns true when a decision was added.
    @discardableResult public mutating func adopt(_ macKey: String, publishNewTags: Bool) -> Bool {
        guard decisions[macKey] == nil else { return false }
        decisions[macKey] = publishNewTags
        return true
    }
    public mutating func setPublishing(_ macKey: String, _ on: Bool) { decisions[macKey] = on }
    /// Returns true when this is the first publish of the tag to that broker.
    @discardableResult public mutating func markPublished(_ macKey: String, brokerKey: String) -> Bool {
        published[brokerKey, default: []].insert(macKey).inserted
    }
    @discardableResult public mutating func queueRemoval(_ macKey: String, settings: HomeAssistantSettings) -> PendingRemoval {
        decisions[macKey] = false
        let removal = PendingRemoval(macKey: macKey, host: settings.host, port: settings.port, prefix: settings.prefix)
        if !pending.contains(removal) { pending.append(removal) }
        return removal
    }
    /// Removes tags this Mac published to this broker and still owns.
    public mutating func queueRemoveAll(settings: HomeAssistantSettings) -> [PendingRemoval] {
        (published[settings.brokerKey] ?? []).filter { decisions[$0] == true }.sorted()
            .map { queueRemoval($0, settings: settings) }
    }
    public func pendingRemovals(for settings: HomeAssistantSettings) -> [PendingRemoval] {
        pending.filter { $0.host == settings.host && $0.port == settings.port && $0.prefix == settings.prefix }
    }
    public mutating func completeRemoval(_ removal: PendingRemoval) {
        pending.removeAll { $0 == removal }
        published[removal.brokerKey]?.remove(removal.macKey)
    }
}

/// At most one state publish per tag per interval.
public struct PublishThrottle {
    public let interval: TimeInterval
    private var last: [String: Date] = [:]
    public init(interval: TimeInterval = 60) { self.interval = interval }
    public mutating func shouldPublish(_ key: String, now: Date) -> Bool {
        if let previous = last[key], now.timeIntervalSince(previous) < interval { return false }
        last[key] = now
        return true
    }
    public mutating func resetAll() { last.removeAll() }
    public mutating func reset(_ key: String) { last[key] = nil }
}

/// Decides whether a reading goes to Home Assistant: Bluetooth only, MAC ids only, owned by this Mac, throttled.
public struct HomeAssistantRouter {
    public var throttle = PublishThrottle()
    public init() {}
    public mutating func route(id: String, source: ReadingSource, connected: Bool, ledger: inout HomeAssistantLedger,
                               publishNewTags: Bool, now: Date) -> String? {
        guard source == .bluetooth, let key = HomeAssistantDiscovery.macKey(id) else { return nil }
        ledger.adopt(key, publishNewTags: publishNewTags)
        guard connected, ledger.isPublishing(key, publishNewTags: publishNewTags),
              throttle.shouldPublish(key, now: now) else { return nil }
        return key
    }
}
```

- [ ] **Step 4: Run and see it pass**

Run: `swift test --build-system native --filter HomeAssistantRoutingTests`
Expected: 6 tests pass.

- [ ] **Step 5: Full suite, commit**

```bash
git add Sources/RuuviCore/HomeAssistantRouting.swift Tests/RuuviCoreTests/HomeAssistantRoutingTests.swift
git commit -m "Add Home Assistant ownership ledger, throttle and publish routing"
```

---

### Task 3: Keychain password store

**Files:**
- Create: `Sources/RuuviCore/KeychainPasswordStore.swift`
- Test: `Tests/RuuviCoreTests/KeychainPasswordStoreTests.swift`

**Interfaces:**
- Produces: `public enum KeychainError: Error, Equatable { case notFound; case status(Int32) }` with `var message: String` (always includes the OSStatus code); `public struct KeychainPasswordStore { init(service: String = "org.ruuvimac.homeassistant"); func read(account:) throws -> String; func save(_:account:) throws; func delete(account:) throws }`. All calls are synchronous; callers use a background queue (Task 5).

`ha.hasPassword == false` is the explicit marker for username-only or anonymous connections; the store is only read when it is true. A missing item while it is true is an error ("Password unavailable from Keychain").

- [ ] **Step 1: Write the failing tests**

The store tests touch the user's real login Keychain, so they run only when `RUUVI_KEYCHAIN_TESTS=1`. The error-message tests are pure and always run.

Create `Tests/RuuviCoreTests/KeychainPasswordStoreTests.swift`:

```swift
import XCTest
@testable import RuuviCore

final class KeychainErrorTests: XCTestCase {
    func testMessagesIncludeStatusCodes() {
        XCTAssertTrue(KeychainError.notFound.message.contains("-25300"))
        XCTAssertTrue(KeychainError.status(-25293).message.contains("-25293"))
        XCTAssertTrue(KeychainError.status(-128).message.contains("-128"))
    }
}

final class KeychainPasswordStoreTests: XCTestCase {
    var store: KeychainPasswordStore!
    let account = "ruuvi@ha.local:1883"
    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["RUUVI_KEYCHAIN_TESTS"] == "1" else { throw XCTSkip("Set RUUVI_KEYCHAIN_TESTS=1 to use the login Keychain") }
        store = KeychainPasswordStore(service: "org.ruuvimac.tests.\(UUID().uuidString)")
    }
    override func tearDownWithError() throws { try? store?.delete(account: account) }

    func testMissingItemIsNotFound() {
        XCTAssertThrowsError(try store.read(account: account)) { XCTAssertEqual($0 as? KeychainError, .notFound) }
    }
    func testSaveReadUpdateDelete() throws {
        try store.save("first", account: account)
        XCTAssertEqual(try store.read(account: account), "first")
        try store.save("second", account: account)
        XCTAssertEqual(try store.read(account: account), "second")
        try store.delete(account: account)
        XCTAssertThrowsError(try store.read(account: account))
        XCTAssertNoThrow(try store.delete(account: account))
    }
}
```

- [ ] **Step 2: Run and see it fail**

Run: `swift test --build-system native --filter Keychain`
Expected: compile failure, `cannot find 'KeychainError' in scope`.

- [ ] **Step 3: Implement**

Create `Sources/RuuviCore/KeychainPasswordStore.swift`:

```swift
import Foundation
import Security

public enum KeychainError: Error, Equatable {
    case notFound
    case status(Int32)
    public var message: String {
        switch self {
        case .notFound: return "No saved password was found in the Keychain (\(errSecItemNotFound))."
        case .status(let code):
            let text = SecCopyErrorMessageString(code, nil) as String? ?? "Keychain error"
            return "\(text) (\(code))"
        }
    }
}

/// Generic password in the user's default (legacy file-based) Keychain. Synchronous; call off the main queue,
/// because access can show a system prompt.
public struct KeychainPasswordStore {
    public let service: String
    public init(service: String = "org.ruuvimac.homeassistant") { self.service = service }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    public func read(account: String) throws -> String {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { throw KeychainError.notFound }
        guard status == errSecSuccess, let data = result as? Data, let text = String(data: data, encoding: .utf8) else {
            throw KeychainError.status(status == errSecSuccess ? errSecDecode : status)
        }
        return text
    }
    /// Updates in place, adding only if missing, so an existing password is never deleted before the new one is stored.
    public func save(_ password: String, account: String) throws {
        let data = Data(password.utf8)
        let update = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError.status(update) }
        var add = query(account)
        add[kSecValueData as String] = data
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }
    public func delete(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
    }
}
```

- [ ] **Step 4: Run and see it pass**

Run: `swift test --build-system native --filter Keychain` (KeychainErrorTests pass, store tests skipped).
Then `RUUVI_KEYCHAIN_TESTS=1 swift test --build-system native --filter KeychainPasswordStoreTests`: 2 tests pass. If macOS shows a Keychain prompt for the test runner, do not answer it on the user's behalf; mark the gated tests as not run in the report.

- [ ] **Step 5: Commit**

```bash
git add Sources/RuuviCore/KeychainPasswordStore.swift Tests/RuuviCoreTests/KeychainPasswordStoreTests.swift
git commit -m "Add Keychain password store for the Home Assistant broker"
```

---

### Task 4: MQTT publisher

**Files:**
- Create: `Sources/RuuviMQTT/MainRunLoop.swift`
- Create: `Sources/RuuviMQTT/HomeAssistantPublisher.swift`
- Test: `Tests/RuuviCoreTests/HomeAssistantPublisherTests.swift` (loopback, gated by `RUUVI_MQTT_TEST_PORT`)

**Interfaces:**
- Consumes: `HomeAssistantDiscovery`, `HomeAssistantSettings`, `PendingRemoval` (Tasks 1, 2); MQTTNIO 2.13.0. Facts checked in its source: `MQTTClient.Configuration(keepAliveInterval:connectTimeout:timeout:userName:password:useSSL:tlsConfiguration:)` where `timeout` bounds ACK waits and defaults to nil; `connect(will:)` keeps the will's retain flag but always sends it at QoS 0; `shutdown` closes the socket without DISCONNECT (the broker then sends the will); `subscribe` returns an `MQTTSuback` whose `returnCodes` may contain `.failure`.
- Produces:
  - `public enum MainRunLoop { static func perform(_:); static func after(_:_:) -> Timer }`: runs blocks on the main run loop in common and modal-panel modes, so they run while AppKit waits on `.terminateLater`.
  - `public final class HomeAssistantPublisher` with `struct Tag { macKey; name; init(macKey:name:) }`, `init(settings:password:bridge:version:)`, `let settings`, callbacks `onStatus`, `onConnected`, `onDisconnected`, `onBirth`, `onRemoved: ((PendingRemoval) -> Void)?`, `private(set) var connected`, `start()`, `publish(tag:reading:rssi:)`, `publishConfig(tag:)`, `remove(_:)`, `stop(timeout: TimeInterval = 2, closed: @escaping () -> Void)`, internal `dropConnectionForTesting()`.

Rules the code below implements:
- All state is main-queue confined; NIO callbacks hop to main and check `self.client === c` before touching state.
- Any failed config, state or removal publish on the current client is treated as a broken connection: the client is shut down and the normal reconnect runs. Pending removals stay in the ledger and are retried by the bridge on the next `onConnected`.
- A rejected birth subscription is a connection failure.
- `stop(closed:)` completes exactly once, asynchronously, on the main run loop, and only after the client has closed. If the broker does not acknowledge within `timeout` seconds the socket is force-closed. Quit adds its own hard deadline in the app delegate.
- After a connection failure, the reconnect is scheduled only after the old client has closed, so the old connection's Last Will cannot arrive after the new `online`.

- [ ] **Step 1: Write the loopback test**

Create `Tests/RuuviCoreTests/HomeAssistantPublisherTests.swift`:

```swift
import XCTest
import MQTTNIO
@testable import RuuviCore
@testable import RuuviMQTT

final class HomeAssistantPublisherTests: XCTestCase {
    /// Records every message an observer client receives, thread-safely.
    final class Inbox {
        private let lock = NSLock()
        private var items: [(topic: String, payload: String)] = []
        func add(_ topic: String, _ payload: String) { lock.lock(); items.append((topic, payload)); lock.unlock() }
        func all() -> [(topic: String, payload: String)] { lock.lock(); defer { lock.unlock() }; return items }
        func clear() { lock.lock(); items.removeAll(); lock.unlock() }
        func waitFor(_ timeout: TimeInterval = 5, _ predicate: ([(topic: String, payload: String)]) -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if predicate(all()) { return true }
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            return predicate(all())
        }
    }

    func observer(port: Int, filters: [String], inbox: Inbox) throws -> MQTTClient {
        let client = MQTTClient(host: "127.0.0.1", port: port, identifier: UUID().uuidString, eventLoopGroupProvider: .createNew)
        client.addPublishListener(named: "inbox") { result in
            guard case .success(let m) = result else { return }
            var b = m.payload
            inbox.add(m.topicName, b.readString(length: b.readableBytes) ?? "")
        }
        _ = try client.connect().wait()
        _ = try client.subscribe(to: filters.map { .init(topicFilter: $0, qos: .atLeastOnce) }).wait()
        return client
    }

    func testDiscoveryAvailabilityBirthWillRemovalAndShutdown() throws {
        XCTAssertTrue(Thread.isMainThread, "callbacks and counters below rely on the main run loop")
        guard let portText = ProcessInfo.processInfo.environment["RUUVI_MQTT_TEST_PORT"], let port = Int(portText) else { throw XCTSkip("No test broker supplied") }
        let run = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let prefix = "ruuvimac-test-\(run.prefix(8))"
        let bridge = String(run.prefix(8)), key = String(run.suffix(12))
        let settings = HomeAssistantSettings(host: "127.0.0.1", port: port, prefix: prefix)
        let availability = HomeAssistantDiscovery.availabilityTopic(bridge: bridge)
        let config = HomeAssistantDiscovery.configTopic(prefix: prefix, macKey: key)
        let state = HomeAssistantDiscovery.stateTopic(macKey: key)
        let inbox = Inbox()
        let watcher = try observer(port: port, filters: ["\(prefix)/#", availability, state], inbox: inbox)
        defer { try? watcher.syncShutdownGracefully() }

        let publisher = HomeAssistantPublisher(settings: settings, password: nil, bridge: bridge, version: "test")
        var connects = 0, births = 0, disconnects = 0
        var removedKeys: [String] = []
        publisher.onConnected = { connects += 1 }
        publisher.onDisconnected = { disconnects += 1 }
        publisher.onBirth = { births += 1 }
        publisher.onRemoved = { removedKeys.append($0.macKey) }
        publisher.start()
        XCTAssertTrue(inbox.waitFor(10) { _ in connects == 1 })
        XCTAssertTrue(inbox.waitFor { $0.contains { $0 == (availability, "online") } })

        // Config is sent before the first state.
        publisher.publish(tag: .init(macKey: key, name: "Sauna"), reading: Reading(date: Date(), temperature: 21), rssi: -60)
        XCTAssertTrue(inbox.waitFor { items in items.contains { $0.topic == state } })
        let topics = inbox.all().map(\.topic)
        XCTAssertLessThan(try XCTUnwrap(topics.firstIndex(of: config)), try XCTUnwrap(topics.firstIndex(of: state)))

        // The config is retained: a later subscriber receives it.
        let lateInbox = Inbox()
        let late = try observer(port: port, filters: [config], inbox: lateInbox)
        XCTAssertTrue(lateInbox.waitFor { $0.contains { $0.topic == config && !$0.payload.isEmpty } })
        try late.syncShutdownGracefully()

        // Home Assistant birth message.
        _ = try watcher.publish(to: HomeAssistantDiscovery.birthTopic(prefix: prefix), payload: .init(string: "online"), qos: .atLeastOnce).wait()
        XCTAssertTrue(inbox.waitFor { _ in births == 1 })

        // Abrupt drop: broker publishes the Last Will, publisher reconnects and republishes online.
        inbox.clear()
        publisher.dropConnectionForTesting()
        XCTAssertTrue(inbox.waitFor(10) { $0.contains { $0 == (availability, "offline") } }, "Last Will not delivered")
        XCTAssertEqual(disconnects, 1)
        XCTAssertTrue(inbox.waitFor(15) { _ in connects == 2 })
        XCTAssertTrue(inbox.waitFor { $0.contains { $0 == (availability, "online") } })

        // Removal: empty retained config, acknowledged.
        publisher.remove(PendingRemoval(macKey: key, host: "127.0.0.1", port: port, prefix: prefix))
        XCTAssertTrue(inbox.waitFor { _ in removedKeys == [key] })
        XCTAssertTrue(inbox.waitFor { $0.contains { $0 == (config, "") } })

        // Ordered shutdown publishes offline and completes once.
        inbox.clear()
        var completions = 0
        publisher.stop { completions += 1 }
        XCTAssertTrue(inbox.waitFor { _ in completions == 1 })
        XCTAssertTrue(inbox.waitFor { $0.contains { $0 == (availability, "offline") } }, "ordered shutdown did not publish offline")
        RunLoop.main.run(until: Date().addingTimeInterval(2.5))
        XCTAssertEqual(completions, 1, "stop must complete exactly once")
        _ = try watcher.publish(to: availability, payload: .init(), qos: .atLeastOnce, retain: true).wait()
    }

    func testStopWithoutConnectionCompletesAsynchronously() {
        let publisher = HomeAssistantPublisher(settings: HomeAssistantSettings(host: "127.0.0.1", port: 1), password: nil, bridge: "00000000", version: "test")
        XCTAssertTrue(Thread.isMainThread)
        var done = false
        publisher.stop { done = true }
        XCTAssertFalse(done, "completion must not run synchronously")
        let deadline = Date().addingTimeInterval(1)
        while !done && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertTrue(done)
    }
}
```

`testStopWithoutConnectionCompletesAsynchronously` needs no broker and always runs.

- [ ] **Step 2: Run and see it fail**

Run: `swift test --build-system native --filter HomeAssistantPublisherTests`
Expected: compile failure, `cannot find 'HomeAssistantPublisher' in scope`.

- [ ] **Step 3: Main run loop helper**

Create `Sources/RuuviMQTT/MainRunLoop.swift`:

```swift
import Foundation

/// Schedules work on the main run loop in common and modal-panel modes. AppKit runs the modal-panel mode while
/// it waits for `.terminateLater`, so quit-time completions must not rely on plain main-queue dispatch.
public enum MainRunLoop {
    private static let modes = [CFRunLoopMode.commonModes.rawValue, "NSModalPanelRunLoopMode" as CFString] as CFArray
    /// Safe to call from any thread.
    public static func perform(_ block: @escaping () -> Void) {
        CFRunLoopPerformBlock(CFRunLoopGetMain(), modes, block)
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }
    /// Call on the main thread. Returns the timer so callers can cancel it.
    @discardableResult public static func after(_ seconds: TimeInterval, _ block: @escaping () -> Void) -> Timer {
        let timer = Timer(timeInterval: seconds, repeats: false) { _ in block() }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: RunLoop.Mode("NSModalPanelRunLoopMode"))
        return timer
    }
}
```

- [ ] **Step 4: Publisher**

Create `Sources/RuuviMQTT/HomeAssistantPublisher.swift`:

```swift
import Foundation
import MQTTNIO
import NIOCore
import RuuviCore

/// Publishes discovery configs, state and availability to a Home Assistant broker.
/// All state is confined to the main queue; NIO callbacks hop back and check the client before use.
public final class HomeAssistantPublisher {
    public struct Tag: Equatable {
        public let macKey: String
        public var name: String
        public init(macKey: String, name: String) { self.macKey = macKey; self.name = name }
    }
    public let settings: HomeAssistantSettings
    private let password: String?
    private let bridge: String
    private let version: String
    public var onStatus: ((String) -> Void)?
    public var onConnected: (() -> Void)?
    public var onDisconnected: (() -> Void)?
    public var onBirth: (() -> Void)?
    public var onRemoved: ((PendingRemoval) -> Void)?
    public private(set) var connected = false
    private var client: MQTTClient?
    private var retry: DispatchWorkItem?
    private var stopped = true
    private var delay: Double = 1
    private var configured: Set<String> = []
    private let identifier = "ruuvimac-ha-" + UUID().uuidString
    private var availability: String { HomeAssistantDiscovery.availabilityTopic(bridge: bridge) }

    public init(settings: HomeAssistantSettings, password: String?, bridge: String, version: String) {
        self.settings = settings; self.password = password; self.bridge = bridge; self.version = version
    }

    public func start() { stopped = false; connect() }

    private func connect() {
        guard !stopped, client == nil else { return }
        onStatus?("Connecting to the Home Assistant broker…")
        let configuration = MQTTClient.Configuration(keepAliveInterval: .seconds(30), connectTimeout: .seconds(10),
            timeout: .seconds(10),
            userName: settings.username.isEmpty ? nil : settings.username,
            password: settings.username.isEmpty ? nil : password,
            useSSL: settings.tls, tlsConfiguration: settings.tls ? .ts(TSTLSConfiguration()) : nil)
        let c = MQTTClient(host: settings.host, port: settings.port, identifier: identifier,
                           eventLoopGroupProvider: .createNew, configuration: configuration)
        client = c
        let availability = self.availability
        let birthTopic = HomeAssistantDiscovery.birthTopic(prefix: settings.prefix)
        c.addPublishListener(named: "birth") { [weak self, weak c] result in
            guard case .success(let message) = result, message.topicName == birthTopic else { return }
            var buffer = message.payload
            let text = buffer.readString(length: buffer.readableBytes)
            DispatchQueue.main.async {
                guard let self, let c, self.client === c, self.connected, text == "online" else { return }
                self.onBirth?()
            }
        }
        c.addCloseListener(named: "reconnect") { [weak self, weak c] _ in
            DispatchQueue.main.async { self?.failed(c, message: "Home Assistant broker disconnected; reconnecting…") }
        }
        // MQTTNIO 2.13.0 sends the will at QoS 0; the retain flag is kept.
        let will = (topicName: availability, payload: ByteBuffer(string: "offline"), qos: MQTTQoS.atLeastOnce, retain: true)
        c.connect(will: will)
            .flatMap { _ in c.publish(to: availability, payload: ByteBuffer(string: "online"), qos: .atLeastOnce, retain: true) }
            .flatMap { c.subscribe(to: [.init(topicFilter: birthTopic, qos: .atLeastOnce)]) }
            .whenComplete { [weak self, weak c] result in
                DispatchQueue.main.async {
                    guard let self, let c, self.client === c, !self.stopped else { return }
                    switch result {
                    case .success(let suback):
                        if suback.returnCodes.contains(where: { if case .failure = $0 { return true }; return false }) {
                            self.failed(c, message: "The broker rejected the Home Assistant status subscription. Retrying…")
                            return
                        }
                        self.delay = 1; self.connected = true; self.configured = []
                        self.onStatus?("Connected to the Home Assistant broker")
                        self.onConnected?()
                    case .failure(let error):
                        self.failed(c, message: Self.describe(error))
                    }
                }
            }
    }

    static func describe(_ error: Error) -> String {
        if case MQTTError.connectionError(let code) = error {
            switch code {
            case .badUserNameOrPassword, .notAuthorized: return "The broker rejected the username or password. Retrying…"
            default: return "The broker refused the connection (\(code)). Retrying…"
            }
        }
        return "Could not reach the Home Assistant broker; check host, port and TLS. Retrying…"
    }

    /// Drops the current client and schedules a reconnect with backoff.
    private func failed(_ c: MQTTClient?, message: String) {
        guard let c, client === c, !stopped else { return }
        client = nil
        if connected { connected = false; onDisconnected?() }
        configured = []
        onStatus?(message)
        let wait = delay
        delay = min(delay * 2, 30)
        c.removeCloseListener(named: "reconnect")
        // Reconnect only after the old socket has closed, so its Last Will cannot land after the new "online".
        c.shutdown { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, !self.stopped else { return }
                let task = DispatchWorkItem { [weak self] in self?.connect() }
                self.retry = task
                DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: task)
            }
        }
    }

    /// Reports a failed publish on `c` as a broken connection, if `c` is still the current client.
    private func publishFailed(_ c: MQTTClient) {
        DispatchQueue.main.async { [weak self] in
            self?.failed(c, message: "Publishing to the Home Assistant broker failed; reconnecting…")
        }
    }

    public func publishConfig(tag: Tag) {
        guard connected, let c = client else { return }
        let payload = HomeAssistantDiscovery.config(macKey: tag.macKey, name: tag.name, bridge: bridge, version: version)
        configured.insert(tag.macKey)
        c.publish(to: HomeAssistantDiscovery.configTopic(prefix: settings.prefix, macKey: tag.macKey),
                  payload: ByteBuffer(bytes: payload), qos: .atLeastOnce, retain: true)
            .whenFailure { [weak self] _ in self?.publishFailed(c) }
    }

    /// Sends the tag's config first if this connection has not sent it yet, then the state.
    public func publish(tag: Tag, reading: Reading, rssi: Int) {
        guard connected, let c = client else { return }
        if !configured.contains(tag.macKey) { publishConfig(tag: tag) }
        c.publish(to: HomeAssistantDiscovery.stateTopic(macKey: tag.macKey),
                  payload: ByteBuffer(bytes: HomeAssistantDiscovery.state(reading, rssi: rssi)), qos: .atMostOnce)
            .whenFailure { [weak self] _ in self?.publishFailed(c) }
    }

    /// Empty retained config at QoS 1. `onRemoved` fires only after the broker acknowledges it.
    public func remove(_ removal: PendingRemoval) {
        guard connected, let c = client, removal.brokerKey == settings.brokerKey else { return }
        configured.remove(removal.macKey)
        c.publish(to: HomeAssistantDiscovery.configTopic(prefix: removal.prefix, macKey: removal.macKey),
                  payload: ByteBuffer(), qos: .atLeastOnce, retain: true)
            .whenComplete { [weak self] result in
                switch result {
                case .success: DispatchQueue.main.async { self?.onRemoved?(removal) }
                case .failure: self?.publishFailed(c)
                }
            }
    }

    /// Ordered shutdown: stop retries, publish retained offline and wait for the ack, disconnect, shut down.
    /// `closed` runs exactly once on the main run loop, never synchronously, after the client has really closed.
    /// If the broker has not acknowledged within `timeout` seconds the socket is closed anyway and the broker's
    /// Last Will marks this bridge offline. Callers that need a hard time bound (quit) add their own deadline.
    public func stop(timeout: TimeInterval = 2, closed: @escaping () -> Void) {
        stopped = true; retry?.cancel(); retry = nil
        let wasConnected = connected
        if connected { connected = false; onDisconnected?() }
        configured = []
        var completed = false
        var deadline: Timer?
        let complete = {
            guard !completed else { return }
            completed = true; deadline?.invalidate(); closed()
        }
        guard let c = client else { MainRunLoop.perform(complete); return }
        client = nil
        c.removeCloseListener(named: "reconnect")
        // shutdown is idempotent; a second call reports alreadyShutdown, which is ignored.
        let finish = { c.shutdown { error in
            if let mqtt = error as? MQTTError, case .alreadyShutdown = mqtt { return }
            MainRunLoop.perform(complete)
        } }
        deadline = MainRunLoop.after(timeout) { finish() }
        guard wasConnected, c.isActive() else { finish(); return }
        c.publish(to: availability, payload: ByteBuffer(string: "offline"), qos: .atLeastOnce, retain: true)
            .flatMap { c.disconnect() }
            .whenComplete { _ in finish() }
    }

    /// Runs the normal failure path: the socket closes without DISCONNECT, so the broker sends the Last Will,
    /// and the reconnect is scheduled after the close completes.
    func dropConnectionForTesting() {
        failed(client, message: "Connection dropped for testing; reconnecting…")
    }
}
```

`complete` is only invoked on the main thread (through `MainRunLoop`), so `completed` and `deadline` need no lock. Only the first `shutdown` call reports completion; a second one returns `alreadyShutdown`, which is ignored.

- [ ] **Step 5: Build and run**

Run: `swift build --build-system native` (must compile cleanly).
Run: `swift test --build-system native --filter HomeAssistantPublisherTests`. `testStopWithoutConnectionCompletesAsynchronously` passes; the loopback test is skipped without `RUUVI_MQTT_TEST_PORT`. If a broker already runs on 127.0.0.1, run with `RUUVI_MQTT_TEST_PORT=<port>`. Do not install a broker; if none is available, record "loopback not run, no broker" in the report.

- [ ] **Step 6: Full suite, commit**

```bash
git add Sources/RuuviMQTT/MainRunLoop.swift Sources/RuuviMQTT/HomeAssistantPublisher.swift Tests/RuuviCoreTests/HomeAssistantPublisherTests.swift
git commit -m "Add Home Assistant MQTT publisher with Last Will, birth handling and bounded shutdown"
```

---

### Task 5: Bridge controller and app wiring

**Files:**
- Create: `Sources/RuuviMac/HomeAssistantBridge.swift`
- Modify: `Sources/RuuviMac/SensorStore.swift` (reading source, callbacks)
- Modify: `Sources/RuuviMac/AppDelegate.swift` (own the bridge, wire callbacks, deferred termination)

**Interfaces:**
- Consumes: Tasks 1 to 4. `SensorStore.receive(id:reading:rssi:)`, `rename(_:to:)`, `AppDelegate.applicationShouldTerminate`.
- Produces:
  - `SensorStore`: `receive(id:reading:rssi:source:)`, `var onReading: ((Sensor, Reading, Int, ReadingSource) -> Void)?`, `var onRename: ((Sensor) -> Void)?`
  - `final class HomeAssistantBridge: ObservableObject` with published `status`, `enabled`, `settings`, `ledger`, `hasPassword`, `keychainProblem`, `connected`, `saving`, `removed: Set<String>`; `start()`, `retryKeychain()`, `apply(settings:enabled:password:clearPassword:completion:)`, `receive(sensor:reading:rssi:source:)`, `renamed(_:)`, `macKey(for:)`, `isPublishing(_:)`, `isRemovalPending(_:)`, `wasRemoved(_:)`, `setPublishing(_:_:)`, `remove(_:)`, `removeAll()`, `shutdown(_:)`.
  - `AppDelegate.homeAssistant: HomeAssistantBridge`.

Lifecycle rules this code implements:
- At most one publisher exists, plus at most one that is stopping. A new publisher starts only after the stopping one has really closed (`restart` → `stop(closed:)` → `start`). `start` refuses to run while either exists.
- `shutdown` (quit) is terminal: `isShutDown` stops `start`, password-save commits and stop continuations from restarting anything.
- A tag's publish choice is recorded on its first Bluetooth sighting while publishing is enabled, even before the publisher connects.
- `generation` increments on every restart and shutdown. Keychain read results check it, so a late read for an old configuration never connects.
- Settings and password metadata change only after the Keychain save succeeds. On failure, the old settings stay active and the sheet shows the error.
- Every publisher callback checks `self.publisher === p` before changing state, except `onRemoved`, which records a real broker acknowledgement.
- Readings go only to the current publisher, using that publisher's own settings for routing and ledger bookkeeping.

No unit tests: this is glue around the tested router, ledger and publisher. Verification is build plus Task 8.

- [ ] **Step 1: Reading source in `SensorStore`**

In `Sources/RuuviMac/SensorStore.swift`:

Add below `@Published var savingPaused = false`:

```swift
    /// Called on main after a reading is accepted. The Home Assistant bridge filters by source.
    var onReading: ((Sensor, Reading, Int, ReadingSource) -> Void)?
    var onRename: ((Sensor) -> Void)?
```

In `useMQTT(_:)`, change the reading callback:

```swift
        input.onReading = { [weak self] sample in self?.receive(id: sample.identity, reading: sample.reading, rssi: sample.rssi, source: .mqtt) }
```

In `centralManager(_:didDiscover:...)`, change the last line to:

```swift
        receive(id: id, reading: decoded.reading, rssi: RSSI.intValue, source: .bluetooth)
```

Replace `receive(id:reading:rssi:)` with:

```swift
    func receive(id: String, reading: Reading, rssi: Int, source: ReadingSource) {
        let index: Int
        if let existing = sensors.firstIndex(where: { $0.id == id }) {
            guard reading.date > sensors[existing].lastSeen else { return }
            sensors[existing].receive(reading, rssi: rssi); index = existing
        } else {
            var sensor = Sensor(id: id, date: reading.date, rssi: rssi, reading: reading)
            sensor.receive(reading, rssi: rssi); sensors.append(sensor); index = sensors.count - 1
        }
        onReading?(sensors[index], reading, rssi, source)
        scheduleSave()
    }
```

In `rename(_:to:)`, after `persist()` add `onRename?(sensors[i])`.

Run `grep -n "receive(id:" Sources` and add `source:` to any other caller; there should be none besides the two above.

- [ ] **Step 2: Bridge controller**

Create `Sources/RuuviMac/HomeAssistantBridge.swift`:

```swift
import Foundation
import Combine
import RuuviCore
import RuuviMQTT

/// Owns Home Assistant settings, the ownership ledger, the Keychain password and the publisher lifecycle.
/// Main queue only. Keychain work runs on `keychainQueue`.
final class HomeAssistantBridge: ObservableObject {
    @Published private(set) var status = "Home Assistant publishing is off"
    @Published private(set) var enabled: Bool
    @Published private(set) var settings: HomeAssistantSettings
    @Published private(set) var ledger: HomeAssistantLedger
    @Published private(set) var hasPassword: Bool
    @Published private(set) var keychainProblem = false
    @Published private(set) var connected = false
    @Published private(set) var saving = false
    /// Tags whose removal the broker acknowledged during this session.
    @Published private(set) var removed: Set<String> = []
    let bridgeID: String
    private let defaults: UserDefaults
    private let keychain = KeychainPasswordStore()
    private let keychainQueue = DispatchQueue(label: "org.ruuvimac.keychain")
    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    private var publisher: HomeAssistantPublisher?
    private var stopping: HomeAssistantPublisher?
    private var router = HomeAssistantRouter()
    /// Latest name of every MAC-identified tag heard over Bluetooth this session, for birth and rename republish.
    private var names: [String: String] = [:]
    private var generation = 0
    /// Set by `shutdown` (quit). Nothing restarts publishing afterwards.
    private var isShutDown = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        settings = defaults.data(forKey: "ha.settings").flatMap { try? JSONDecoder().decode(HomeAssistantSettings.self, from: $0) }
            ?? HomeAssistantSettings(host: "homeassistant.local")
        ledger = defaults.data(forKey: "ha.ledger").flatMap { try? JSONDecoder().decode(HomeAssistantLedger.self, from: $0) }
            ?? HomeAssistantLedger()
        enabled = defaults.bool(forKey: "ha.enabled")
        hasPassword = defaults.bool(forKey: "ha.hasPassword")
        if let saved = defaults.string(forKey: "ha.bridgeID") { bridgeID = saved }
        else { bridgeID = HomeAssistantDiscovery.newBridgeID(); defaults.set(bridgeID, forKey: "ha.bridgeID") }
    }

    private static func describe(_ error: Error) -> String {
        (error as? KeychainError)?.message ?? error.localizedDescription
    }

    // MARK: Lifecycle

    /// Starts publishing with the current settings if enabled and no publisher is running or stopping.
    func start() {
        guard !isShutDown, publisher == nil, stopping == nil else { return }
        generation += 1
        let current = generation, config = settings
        keychainProblem = false
        guard enabled else { status = "Home Assistant publishing is off"; return }
        if let problem = config.validationError { status = problem; return }
        // ha.hasPassword false means username-only or anonymous; the Keychain is not read.
        guard !config.username.isEmpty, hasPassword else { connect(config, password: nil); return }
        status = "Reading the broker password from the Keychain…"
        let store = keychain
        keychainQueue.async {
            let result = Result { try store.read(account: config.account) }
            DispatchQueue.main.async {
                guard current == self.generation, self.publisher == nil, self.stopping == nil else { return }
                switch result {
                case .success(let password): self.connect(config, password: password)
                case .failure(let error):
                    self.keychainProblem = true
                    self.status = "Password unavailable from Keychain: " + Self.describe(error)
                }
            }
        }
    }

    func retryKeychain() { generation += 1; start() }

    private func connect(_ config: HomeAssistantSettings, password: String?) {
        let p = HomeAssistantPublisher(settings: config, password: password, bridge: bridgeID, version: version)
        p.onStatus = { [weak self, weak p] text in
            guard let self, let p, self.publisher === p else { return }
            self.status = text
        }
        p.onConnected = { [weak self, weak p] in
            guard let self, let p, self.publisher === p else { return }
            self.connected = true
            self.router.throttle.resetAll()
            let count = self.ledger.published[config.brokerKey]?.count ?? 0
            self.status = "Connected to the Home Assistant broker · \(count) tags published"
            for removal in self.ledger.pendingRemovals(for: config) { p.remove(removal) }
        }
        p.onDisconnected = { [weak self, weak p] in
            guard let self, let p, self.publisher === p else { return }
            self.connected = false
        }
        p.onBirth = { [weak self, weak p] in
            guard let self, let p, self.publisher === p else { return }
            self.router.throttle.resetAll()
            for (key, name) in self.names where self.ledger.isPublishing(key, publishNewTags: config.publishNewTags) {
                p.publishConfig(tag: .init(macKey: key, name: name))
            }
        }
        p.onRemoved = { [weak self] removal in
            guard let self else { return }
            var next = self.ledger
            next.completeRemoval(removal)
            self.ledger = next; self.saveLedger()
            self.removed.insert(removal.macKey)
        }
        publisher = p
        p.start()
    }

    /// Stops the running publisher, if any, and starts again with the current settings once it has stopped.
    private func restart() {
        generation += 1
        connected = false
        guard let old = publisher else { start(); return }
        publisher = nil
        stopping = old
        old.stop { [weak self] in
            guard let self else { return }
            if self.stopping === old { self.stopping = nil }
            self.start()   // no-op after shutdown
        }
    }

    /// Quit path, terminal: no later save, Keychain read or stop continuation restarts publishing.
    /// Completion runs on the main run loop, never synchronously, once the running publisher has closed.
    /// The app delegate adds the hard 2 second bound.
    func shutdown(_ completion: @escaping () -> Void) {
        isShutDown = true
        generation += 1
        connected = false
        guard let p = publisher else { MainRunLoop.perform(completion); return }
        publisher = nil
        p.stop(closed: completion)
    }

    // MARK: Settings

    /// Validates, stores the password first, then commits the settings and restarts.
    /// Completion receives an error message, or nil once the new settings are active. Old settings stay on failure.
    func apply(settings new: HomeAssistantSettings, enabled newEnabled: Bool, password: String, clearPassword: Bool,
               completion: @escaping (String?) -> Void) {
        guard !saving else { completion("Still saving the previous change."); return }
        if newEnabled, let problem = new.validationError { completion(problem); return }
        let oldAccount = settings.account
        let hadPassword = hasPassword
        let accountChanged = new.account != oldAccount
        let noPassword = new.username.isEmpty || clearPassword
        if !noPassword, password.isEmpty, hadPassword, accountChanged {
            completion("Enter the password again for the new username, host or port."); return
        }
        let commit: (Bool?) -> Void = { [weak self] passwordStored in
            guard let self, !self.isShutDown else { return }
            self.settings = new; self.enabled = newEnabled
            if let stored = passwordStored { self.hasPassword = stored; self.defaults.set(stored, forKey: "ha.hasPassword") }
            self.defaults.set(try? JSONEncoder().encode(new), forKey: "ha.settings")
            self.defaults.set(newEnabled, forKey: "ha.enabled")
            self.restart()
            completion(nil)
        }
        let store = keychain
        if noPassword {
            guard hadPassword else { commit(false); return }
            saving = true
            keychainQueue.async {
                let result = Result { try store.delete(account: oldAccount) }
                DispatchQueue.main.async {
                    self.saving = false
                    switch result {
                    case .success: commit(false)
                    case .failure(let error): completion("Could not remove the saved password: " + Self.describe(error))
                    }
                }
            }
        } else if !password.isEmpty {
            saving = true
            let account = new.account
            keychainQueue.async {
                let result = Result { try store.save(password, account: account) }
                if case .success = result, hadPassword, account != oldAccount { try? store.delete(account: oldAccount) }
                DispatchQueue.main.async {
                    self.saving = false
                    switch result {
                    case .success: commit(true)
                    case .failure(let error): completion("Could not save the password in the Keychain: " + Self.describe(error))
                    }
                }
            }
        } else {
            commit(nil)
        }
    }

    // MARK: Readings

    func receive(sensor: Sensor, reading: Reading, rssi: Int, source: ReadingSource) {
        guard source == .bluetooth, let key = HomeAssistantDiscovery.macKey(sensor.id) else { return }
        names[key] = sensor.name
        var next = ledger
        // Record the publish choice on first sighting while publishing is enabled, even before the
        // publisher is connected (Keychain prompt, replacement), so a later default change cannot flip it.
        if enabled { next.adopt(key, publishNewTags: settings.publishNewTags) }
        guard let p = publisher else {
            if next != ledger { ledger = next; saveLedger() }
            return
        }
        if let routed = router.route(id: sensor.id, source: source, connected: p.connected, ledger: &next,
                                     publishNewTags: p.settings.publishNewTags, now: Date()) {
            p.publish(tag: .init(macKey: routed, name: sensor.name), reading: reading, rssi: rssi)
            if next.markPublished(routed, brokerKey: p.settings.brokerKey) {
                status = "Connected to the Home Assistant broker · \(next.published[p.settings.brokerKey]?.count ?? 0) tags published"
            }
        }
        // Assign only on change: this runs for every advertisement and `ledger` is published.
        if next != ledger { ledger = next; saveLedger() }
    }

    func renamed(_ sensor: Sensor) {
        guard let key = HomeAssistantDiscovery.macKey(sensor.id) else { return }
        names[key] = sensor.name
        guard let p = publisher, ledger.isPublishing(key, publishNewTags: p.settings.publishNewTags),
              ledger.published[p.settings.brokerKey]?.contains(key) == true else { return }
        p.publishConfig(tag: .init(macKey: key, name: sensor.name))
    }

    // MARK: Per-tag controls

    func macKey(for id: String) -> String? { HomeAssistantDiscovery.macKey(id) }
    func isPublishing(_ id: String) -> Bool {
        macKey(for: id).map { ledger.isPublishing($0, publishNewTags: settings.publishNewTags) } ?? false
    }
    func isRemovalPending(_ id: String) -> Bool { macKey(for: id).map(ledger.isRemovalPending) ?? false }
    func wasRemoved(_ id: String) -> Bool { macKey(for: id).map(removed.contains) ?? false }

    func setPublishing(_ id: String, _ on: Bool) {
        guard let key = macKey(for: id), !ledger.isRemovalPending(key) else { return }
        var next = ledger
        next.setPublishing(key, on)
        ledger = next; saveLedger()
        if on { router.throttle.reset(key); removed.remove(key) }
    }

    func remove(_ id: String) {
        guard let key = macKey(for: id) else { return }
        var next = ledger
        let removal = next.queueRemoval(key, settings: publisher?.settings ?? settings)
        ledger = next; saveLedger()
        removed.remove(key)
        publisher?.remove(removal)
    }

    func removeAll() {
        var next = ledger
        let removals = next.queueRemoveAll(settings: publisher?.settings ?? settings)
        ledger = next; saveLedger()
        for removal in removals { removed.remove(removal.macKey); publisher?.remove(removal) }
    }

    private func saveLedger() { defaults.set(try? JSONEncoder().encode(ledger), forKey: "ha.ledger") }
}
```

- [ ] **Step 3: App delegate wiring**

In `Sources/RuuviMac/AppDelegate.swift`:

Add `import RuuviMQTT` at the top of `AppDelegate.swift` (for `MainRunLoop`), and `let homeAssistant = HomeAssistantBridge()` after `let loginItem = LoginItem()`.

At the start of `applicationDidFinishLaunching`, before the activity token, add:

```swift
        store.onReading = { [weak self] sensor, reading, rssi, source in
            self?.homeAssistant.receive(sensor: sensor, reading: reading, rssi: rssi, source: source)
        }
        store.onRename = { [weak self] sensor in self?.homeAssistant.renamed(sensor) }
        homeAssistant.start()
```

Replace `applicationShouldTerminate`:

```swift
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard homeAssistant.connected else { return .terminateNow }
        // Publish retained offline first. Both paths reply on the main run loop in modal-panel mode,
        // after this method has returned, and never later than 2 seconds.
        var replied = false
        let reply = {
            guard !replied else { return }
            replied = true
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        homeAssistant.shutdown(reply)
        // Hard bound for quit; scheduled in modal-panel mode so it fires while AppKit waits.
        MainRunLoop.after(2, reply)
        return .terminateLater
    }
```

`applicationWillTerminate` still saves the archive after the reply.

- [ ] **Step 4: Build and test**

Run: `swift test --build-system native` and `./scripts/build-app.sh`. Both succeed.

- [ ] **Step 5: Commit**

```bash
git add Sources/RuuviMac/HomeAssistantBridge.swift Sources/RuuviMac/SensorStore.swift Sources/RuuviMac/AppDelegate.swift
git commit -m "Publish Bluetooth readings to Home Assistant and send offline before quit"
```

---

### Task 6: Settings sheet and per-tag controls

**Files:**
- Create: `Sources/RuuviMac/HomeAssistantSettingsView.swift`
- Modify: `Sources/RuuviMac/RuuviMacApp.swift` (bottom bar button, sheet, pass bridge to `SensorDetail`, per-tag controls)
- Modify: `Sources/RuuviMac/AppDelegate.swift` (`SelectionModel.showHomeAssistant`)
- Modify: `Sources/RuuviMac/MenuBarView.swift` (menu item and status line)

**Interfaces:**
- Consumes: `HomeAssistantBridge` (Task 5), `AppDelegate.homeAssistant`, `SelectionModel`, `MenuBarView.open(select:)`.
- Produces: `struct HomeAssistantSettingsView: View` with `init(bridge:)`; `SelectionModel.showHomeAssistant: Bool`; `ContentView(store:selection:loginItem:homeAssistant:)`; `SensorDetail(sensor:store:homeAssistant:)`; `MenuBarView(store:selection:loginItem:homeAssistant:delegate:)`.

- [ ] **Step 1: Settings sheet**

Create `Sources/RuuviMac/HomeAssistantSettingsView.swift`:

```swift
import SwiftUI
import RuuviCore

struct HomeAssistantSettingsView: View {
    @ObservedObject var bridge: HomeAssistantBridge
    @Environment(\.dismiss) private var dismiss
    @State private var enabled = false
    @State private var host = ""
    @State private var port = 1883
    @State private var tls = false
    @State private var username = ""
    @State private var password = ""
    @State private var clearPassword = false
    @State private var prefix = ""
    @State private var publishNewTags = true
    @State private var issue: String?
    @State private var confirmRemoveAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Home Assistant").font(.title2)
            Text("Publish RuuviTags heard over Bluetooth to your Home Assistant MQTT broker. Each tag appears as a device through MQTT discovery.")
                .foregroundStyle(.secondary)
            Form {
                Toggle("Publish to Home Assistant", isOn: $enabled)
                TextField("Broker hostname", text: $host)
                TextField("Port", value: $port, format: .number.grouping(.never))
                Toggle("Use TLS with trusted certificates", isOn: $tls)
                TextField("Username", text: $username)
                SecureField(bridge.hasPassword ? "Password (leave empty to keep the saved one)" : "Password (optional)", text: $password)
                if bridge.hasPassword { Toggle("Remove the saved password", isOn: $clearPassword) }
                TextField("Discovery prefix", text: $prefix)
                Toggle("Publish newly discovered tags", isOn: $publishNewTags)
            }
            Text("Publish each tag from one Mac only. Turn off publishing for a tag on the other Macs. Changing the broker or prefix leaves devices on the old broker; remove them first.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Circle().fill(bridge.connected ? Color.green : Color.secondary).frame(width: 7, height: 7)
                Text(bridge.status).font(.caption).lineLimit(2)
                if bridge.keychainProblem { Button("Try again") { bridge.retryKeychain() } }
            }
            if let issue { Text(issue).foregroundStyle(.red) }
            HStack {
                Button("Remove all devices from this broker…") { confirmRemoveAll = true }
                    .disabled(!bridge.enabled)
                Spacer()
                if bridge.saving { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }
                Button("Save") {
                    issue = nil
                    let settings = HomeAssistantSettings(host: host.trimmingCharacters(in: .whitespacesAndNewlines), port: port,
                        tls: tls, username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                        prefix: prefix.trimmingCharacters(in: .whitespacesAndNewlines), publishNewTags: publishNewTags)
                    bridge.apply(settings: settings, enabled: enabled, password: password, clearPassword: clearPassword) { problem in
                        if let problem { issue = problem } else { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(bridge.saving)
            }
        }
        .padding(24).frame(width: 540)
        .onAppear {
            let s = bridge.settings
            enabled = bridge.enabled; host = s.host; port = s.port; tls = s.tls; username = s.username
            prefix = s.prefix; publishNewTags = s.publishNewTags
        }
        .confirmationDialog("Remove every tag this Mac publishes to this broker from Home Assistant?",
                            isPresented: $confirmRemoveAll) {
            Button("Remove all", role: .destructive) { bridge.removeAll() }
        }
    }
}
```

- [ ] **Step 2: Window routing flag**

In `Sources/RuuviMac/AppDelegate.swift`, add to `SelectionModel`:

```swift
    /// Set by the menu to open the Home Assistant sheet in the main window.
    @Published var showHomeAssistant = false
```

- [ ] **Step 3: Main window**

In `Sources/RuuviMac/RuuviMacApp.swift`:

- `RuuviMacApp`: pass `homeAssistant: delegate.homeAssistant` to `ContentView`, and to `MenuBarView` (argument order `store:selection:loginItem:homeAssistant:delegate:`).
- `ContentView`: add `@ObservedObject var homeAssistant: HomeAssistantBridge`. Pass it to `SensorDetail(sensor: sensor, store: store, homeAssistant: homeAssistant)`. In the bottom bar, before `Button("MQTT settings…")`, add `Button("Home Assistant…") { selection.showHomeAssistant = true }`. After the existing `.sheet(isPresented: $mqttSettings)`, add:

```swift
        .sheet(isPresented: $selection.showHomeAssistant) { HomeAssistantSettingsView(bridge: homeAssistant) }
```

- `SensorDetail`: add `@ObservedObject var homeAssistant: HomeAssistantBridge`. After the "Download tag history" `HStack`, add:

```swift
                if homeAssistant.enabled, homeAssistant.macKey(for: sensor.id) != nil {
                    HStack {
                        Toggle("Publish to Home Assistant", isOn: Binding(
                            get: { homeAssistant.isPublishing(sensor.id) },
                            set: { homeAssistant.setPublishing(sensor.id, $0) }))
                        .disabled(homeAssistant.isRemovalPending(sensor.id))
                        Button(homeAssistant.isRemovalPending(sensor.id) ? "Removing…" : "Remove from Home Assistant") {
                            homeAssistant.remove(sensor.id)
                        }.disabled(homeAssistant.isRemovalPending(sensor.id))
                        if homeAssistant.wasRemoved(sensor.id) { Text("Removed").foregroundStyle(.secondary) }
                    }
                    Text("Turning publishing off keeps the device in Home Assistant so another Mac can publish it. Remove deletes the device.")
                        .font(.caption).foregroundStyle(.secondary)
                }
```

- [ ] **Step 4: Menu**

In `Sources/RuuviMac/MenuBarView.swift`: add `@ObservedObject var homeAssistant: HomeAssistantBridge` after `loginItem` (memberwise order `store, selection, loginItem, homeAssistant, delegate`). After `Text(store.status)` add:

```swift
        if homeAssistant.enabled { Text("Home Assistant: \(homeAssistant.status)") }
```

Before `Button("Open RuuviMac…")` add:

```swift
        Button("Home Assistant…") { open(select: nil); selection.showHomeAssistant = true }
```

- [ ] **Step 5: Build, test, commit**

Run: `swift test --build-system native` and `./scripts/build-app.sh`.

```bash
git add Sources/RuuviMac/HomeAssistantSettingsView.swift Sources/RuuviMac/RuuviMacApp.swift Sources/RuuviMac/AppDelegate.swift Sources/RuuviMac/MenuBarView.swift
git commit -m "Add Home Assistant settings, per-tag publishing controls and menu status"
```

---

### Task 7: Docs and version

**Files:**
- Modify: `README.md` (new "Home Assistant bridge (v0.5)" section after the v0.4 section; "Validation and limitations" line)
- Modify: `VALIDATION.md` (new "Home Assistant bridge v0.5" section)
- Modify: `Resources/Info.plist` (`CFBundleShortVersionString` 0.5.0, `CFBundleVersion` 6)

- [ ] **Step 1: README section**

Add after the v0.4 section:

```markdown
## Home Assistant bridge (v0.5)

RuuviMac can publish the RuuviTags it hears over Bluetooth to the MQTT broker used by Home Assistant's MQTT integration. Each tag appears as a device with temperature, humidity, pressure, battery voltage, signal strength and movement counter entities, through MQTT discovery. No Home Assistant YAML is needed.

Open **Home Assistant…** in the window or the menu bar. Enter the broker host, port, TLS setting, username and password. The default discovery prefix is `homeassistant`. The password is stored in your login Keychain. With this ad-hoc signed build, macOS may ask again whether RuuviMac can use the saved password after each rebuild; choose Always Allow. If the Keychain cannot be read, publishing waits and shows Try again.

Only Bluetooth readings are published. Readings from MQTT input are not, since they are already on a broker. Tags without a MAC address are skipped. Each tag publishes at most once a minute. Entities become unavailable when RuuviMac quits or loses its broker connection, and about ten minutes after a tag stops being heard.

Several Macs can publish to the same broker, but each tag should be published by one Mac only. Turn off **Publish to Home Assistant** for that tag on the other Macs. **Remove from Home Assistant** deletes the device; if the broker is unreachable, the removal is retried on the next connection. Changing the broker or prefix leaves existing devices on the old broker, so use **Remove all devices from this broker** first.

Topics: discovery configs at `<prefix>/device/ruuvi_<mac>/config` (retained), state at `ruuvimac/<mac>/state`, and availability at `ruuvimac/<bridge>/status` with an MQTT Last Will. RuuviMac republishes configs when Home Assistant sends `online` to `<prefix>/status`.
```

- [ ] **Step 2: Limitations line**

In "Validation and limitations", change "No cloud sync, alarms, CSV export, or firmware updates in v0.4." to "No cloud sync, alarms, CSV export, or firmware updates in v0.5."

- [ ] **Step 3: Version**

`Resources/Info.plist`: `CFBundleShortVersionString` 0.5.0, `CFBundleVersion` 6.

- [ ] **Step 4: VALIDATION section**

Add "Home Assistant bridge v0.5" with: unit test count and result; whether the Keychain tests (`RUUVI_KEYCHAIN_TESTS=1`) and the loopback publisher test (`RUUVI_MQTT_TEST_PORT`) ran, with results or "not run" and why; Swift and Xcode versions; build result; and the Task 8 manual list, each marked passed, failed, or pending user test. Report only what was run.

- [ ] **Step 5: Build and commit**

Run `swift test --build-system native` and `./scripts/build-app.sh`, then:

```bash
git add README.md VALIDATION.md Resources/Info.plist
git commit -m "Document the Home Assistant bridge for v0.5"
```

---

### Task 8: Manual verification list (user-run)

No code. This is the checklist the user runs with their Home Assistant; the controller copies results into VALIDATION.md afterward.

1. Settings: enable with the broker details. Status reaches "Connected to the Home Assistant broker". A wrong password shows the credentials message and keeps retrying.
2. Home Assistant shows one device per nearby tag with six entities; values match the app.
3. Rename a tag in RuuviMac. The device name in Home Assistant changes; no second device appears.
4. Restart Home Assistant. Devices and values return within about a minute.
5. Quit RuuviMac while connected. It quits within about 2 seconds, entities become unavailable, and relaunch shows the latest readings.
6. Turn off Wi-Fi or stop the broker, then restore it. Status shows retrying, then connected; values resume.
7. Turn off publishing for one tag. Its entities go unavailable after about ten minutes; the device stays.
8. Remove one tag while the broker is unreachable, relaunch with the broker reachable. The device disappears from Home Assistant.
9. Keychain across rebuilds: build, save the password, rebuild, launch normally and as a login item. Record whether macOS prompts, what Always Allow does, and what Deny plus Try again does. During an unanswered prompt, readings in the menu keep updating.
10. Two bridges: run with a second `ha.bridgeID` (`defaults write org.ruuvimac.app ha.bridgeID 11111111` on a second Mac or after quitting) and confirm quitting one does not mark the other's tags unavailable.

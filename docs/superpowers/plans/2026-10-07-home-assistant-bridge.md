# Home Assistant MQTT bridge implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** RuuviMac publishes the RuuviTags it hears over Bluetooth to a Home Assistant MQTT broker with device discovery, one owning Mac per tag, with the broker password in the Keychain.

**Architecture:** Pure, tested logic lives in `RuuviCore`: discovery topics and payloads, settings validation, a publish router (source filter, MAC check, ownership ledger, 60 second throttle) and a Keychain password store. `RuuviMQTT` gains a thin `HomeAssistantPublisher` (MQTTNIO client with Last Will, reconnect, birth subscription, acknowledged removals, ordered shutdown). `RuuviMac` gains a `HomeAssistantBridge` controller owned by the app delegate, a settings sheet and per-tag controls.

**Tech Stack:** Swift 5.9 tools, SwiftUI + AppKit (macOS 13+), MQTTNIO 2.13.0 (already pinned), Security framework, XCTest.

**Spec:** `docs/superpowers/specs/2026-10-07-home-assistant-bridge-design.md`

**Base:** branch `feature/ha-bridge`, stacked on `feature/background-menubar` (PR #1). It uses PR #1's `AppDelegate`, `applicationShouldTerminate` hook, `MenuBarView` and `SelectionModel`.

## Global Constraints

- Deployment target stays macOS 13. No API newer than macOS 13 without `if #available`. Swift tools 5.9, Swift 5 mode.
- No new package dependencies. MQTTNIO stays at 2.13.0.
- Entitlements unchanged (sandbox, Bluetooth, network client). Network client covers outbound MQTT.
- Only Bluetooth-sourced readings from MAC-identified tags are published. MQTT-input readings are never published.
- Keychain: legacy file-based Keychain, `kSecClassGenericPassword`, service `org.ruuvimac.homeassistant`, account `username@host:port`, no `kSecUseDataProtectionKeychain`, no synchronization, default ACL. Keychain calls never run on the main queue.
- MQTT input passwords stay session-only.
- Topics and ids exactly as in the spec: availability `ruuvimac/<bridge>/status`, state `ruuvimac/<mac>/state`, config `<prefix>/device/ruuvi_<mac>/config`, birth `<prefix>/status`, device id `ruuvimac_<mac>`, entity ids `ruuvimac_<mac>_<field>`, `exp_aft` 600, throttle 60 seconds, bridge id 8 lowercase hex digits in `ha.bridgeID`.
- Config retained QoS 1. State not retained QoS 0. Availability retained QoS 1, Last Will retained `offline`.
- Quit waits at most 2 seconds for the ordered shutdown.
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
  - `public struct HomeAssistantLedger: Codable, Equatable` with `isPublishing(_:publishNewTags:)`, `isRemovalPending(_:)`, `setPublishing(_:_:)`, `markPublished(_:brokerKey:) -> Bool`, `queueRemoval(_:settings:) -> PendingRemoval`, `queueRemoveAll(settings:) -> [PendingRemoval]`, `pendingRemovals(for:) -> [PendingRemoval]`, `completeRemoval(_:)`.
  - `public struct PublishThrottle` with `init(interval: TimeInterval = 60)`, `shouldPublish(_:now:) -> Bool`, `resetAll()`, `reset(_:)`.
  - `public struct HomeAssistantRouter` with `var throttle`, `mutating func route(id: String, source: ReadingSource, connected: Bool, ledger: HomeAssistantLedger, publishNewTags: Bool, now: Date) -> String?` returning the mac key to publish.

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
        XCTAssertFalse(throttle.shouldPublish(key, now: t0.addingTimeInterval(59)))
        XCTAssertTrue(throttle.shouldPublish(key, now: t0.addingTimeInterval(60)))
        throttle.resetAll()
        XCTAssertTrue(throttle.shouldPublish(key, now: t0.addingTimeInterval(61)))
        throttle.reset(key)
        XCTAssertTrue(throttle.shouldPublish(key, now: t0.addingTimeInterval(62)))
        XCTAssertTrue(throttle.shouldPublish("other", now: t0.addingTimeInterval(62)))
    }

    func testRouterFiltersSourceIdentityConnectionAndOwnership() {
        var router = HomeAssistantRouter()
        var ledger = HomeAssistantLedger()
        XCTAssertNil(router.route(id: mac, source: .mqtt, connected: true, ledger: ledger, publishNewTags: true, now: t0))
        XCTAssertNil(router.route(id: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F", source: .bluetooth, connected: true, ledger: ledger, publishNewTags: true, now: t0))
        XCTAssertNil(router.route(id: mac, source: .bluetooth, connected: false, ledger: ledger, publishNewTags: true, now: t0))
        // A disconnected attempt must not consume the throttle.
        XCTAssertEqual(router.route(id: mac, source: .bluetooth, connected: true, ledger: ledger, publishNewTags: true, now: t0), key)
        XCTAssertNil(router.route(id: mac, source: .bluetooth, connected: true, ledger: ledger, publishNewTags: true, now: t0.addingTimeInterval(10)))
        ledger.setPublishing(key, false)
        router.throttle.resetAll()
        XCTAssertNil(router.route(id: mac, source: .bluetooth, connected: true, ledger: ledger, publishNewTags: true, now: t0.addingTimeInterval(100)))
    }

    func testPublishNewTagsOffRequiresOptIn() {
        var ledger = HomeAssistantLedger()
        XCTAssertFalse(ledger.isPublishing(key, publishNewTags: false))
        XCTAssertTrue(ledger.isPublishing(key, publishNewTags: true))
        ledger.setPublishing(key, true)
        XCTAssertTrue(ledger.isPublishing(key, publishNewTags: false))
        ledger.setPublishing(key, false)
        XCTAssertFalse(ledger.isPublishing(key, publishNewTags: true))
    }

    func testRemovalLifecycle() throws {
        var ledger = HomeAssistantLedger()
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
        // Survives a restart (UserDefaults round trip) until acknowledged.
        let restored = try JSONDecoder().decode(HomeAssistantLedger.self, from: JSONEncoder().encode(ledger))
        XCTAssertEqual(restored.pendingRemovals(for: settings), [removal])
        ledger.completeRemoval(removal)
        XCTAssertFalse(ledger.isRemovalPending(key))
        XCTAssertEqual(ledger.pendingRemovals(for: settings), [])
        XCTAssertFalse(ledger.isPublishing(key, publishNewTags: true))
    }

    func testRemoveAllCoversOnlyThisBroker() {
        var ledger = HomeAssistantLedger()
        _ = ledger.markPublished("aaaaaaaaaaaa", brokerKey: settings.brokerKey)
        _ = ledger.markPublished("bbbbbbbbbbbb", brokerKey: settings.brokerKey)
        _ = ledger.markPublished("cccccccccccc", brokerKey: HomeAssistantSettings(host: "other.local").brokerKey)
        let queued = ledger.queueRemoveAll(settings: settings)
        XCTAssertEqual(Set(queued.map(\.macKey)), ["aaaaaaaaaaaa", "bbbbbbbbbbbb"])
        XCTAssertTrue(ledger.isPublishing("cccccccccccc", publishNewTags: true))
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
    public private(set) var disabled: Set<String> = []
    public private(set) var enabled: Set<String> = []
    public private(set) var published: [String: Set<String>] = [:]
    public private(set) var pending: [PendingRemoval] = []
    public init() {}

    public func isRemovalPending(_ macKey: String) -> Bool { pending.contains { $0.macKey == macKey } }
    public func isPublishing(_ macKey: String, publishNewTags: Bool) -> Bool {
        !disabled.contains(macKey) && !isRemovalPending(macKey) && (publishNewTags || enabled.contains(macKey))
    }
    public mutating func setPublishing(_ macKey: String, _ on: Bool) {
        if on { disabled.remove(macKey); enabled.insert(macKey) } else { enabled.remove(macKey); disabled.insert(macKey) }
    }
    /// Returns true when this is the first publish of the tag to that broker.
    @discardableResult public mutating func markPublished(_ macKey: String, brokerKey: String) -> Bool {
        published[brokerKey, default: []].insert(macKey).inserted
    }
    @discardableResult public mutating func queueRemoval(_ macKey: String, settings: HomeAssistantSettings) -> PendingRemoval {
        setPublishing(macKey, false)
        let removal = PendingRemoval(macKey: macKey, host: settings.host, port: settings.port, prefix: settings.prefix)
        if !pending.contains(removal) { pending.append(removal) }
        return removal
    }
    public mutating func queueRemoveAll(settings: HomeAssistantSettings) -> [PendingRemoval] {
        (published[settings.brokerKey] ?? []).sorted().map { queueRemoval($0, settings: settings) }
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
    public mutating func route(id: String, source: ReadingSource, connected: Bool, ledger: HomeAssistantLedger,
                               publishNewTags: Bool, now: Date) -> String? {
        guard source == .bluetooth, connected, let key = HomeAssistantDiscovery.macKey(id),
              ledger.isPublishing(key, publishNewTags: publishNewTags),
              throttle.shouldPublish(key, now: now) else { return nil }
        return key
    }
}
```

- [ ] **Step 4: Run and see it pass**

Run: `swift test --build-system native --filter HomeAssistantRoutingTests`
Expected: 5 tests pass.

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
- Produces: `public enum KeychainError: Error, Equatable { case notFound; case status(Int32) }` with `var message: String`; `public struct KeychainPasswordStore { init(service: String = "org.ruuvimac.homeassistant"); func read(account:) throws -> String; func save(_:account:) throws; func delete(account:) throws }`. All calls are synchronous; callers must use a background queue (Task 5).

- [ ] **Step 1: Write the failing tests**

These touch the user's real login Keychain, so they run only when `RUUVI_KEYCHAIN_TESTS=1`. Each test uses a unique service and deletes its item.

Create `Tests/RuuviCoreTests/KeychainPasswordStoreTests.swift`:

```swift
import XCTest
@testable import RuuviCore

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
    func testErrorMessages() {
        XCTAssertFalse(KeychainError.notFound.message.isEmpty)
        XCTAssertTrue(KeychainError.status(-25293).message.contains("-25293"))
    }
}
```

- [ ] **Step 2: Run and see it fail**

Run: `RUUVI_KEYCHAIN_TESTS=1 swift test --build-system native --filter KeychainPasswordStoreTests`
Expected: compile failure, `cannot find 'KeychainPasswordStore' in scope`.

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
        case .notFound: return "No saved password was found in the Keychain."
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

Run: `RUUVI_KEYCHAIN_TESTS=1 swift test --build-system native --filter KeychainPasswordStoreTests`
Expected: 3 tests pass. If macOS shows a Keychain prompt for the test runner, record it in the report and do not click on the user's behalf; mark as not run.
Then `swift test --build-system native` (without the variable): the 3 tests are skipped.

- [ ] **Step 5: Commit**

```bash
git add Sources/RuuviCore/KeychainPasswordStore.swift Tests/RuuviCoreTests/KeychainPasswordStoreTests.swift
git commit -m "Add Keychain password store for the Home Assistant broker"
```

---

### Task 4: MQTT publisher

**Files:**
- Create: `Sources/RuuviMQTT/HomeAssistantPublisher.swift`
- Test: `Tests/RuuviCoreTests/HomeAssistantPublisherTests.swift` (loopback, gated by `RUUVI_MQTT_TEST_PORT`)

**Interfaces:**
- Consumes: `HomeAssistantDiscovery`, `HomeAssistantSettings`, `PendingRemoval` (Tasks 1, 2); MQTTNIO 2.13.0 `MQTTClient(host:port:identifier:eventLoopGroupProvider:configuration:)`, `connect(cleanSession:will:)`, `publish(to:payload:qos:retain:)`, `subscribe(to:)`, `disconnect()`, `shutdown(_:)`, `isActive()`, `addPublishListener`, `addCloseListener`, `removeCloseListener`.
- Produces: `public final class HomeAssistantPublisher` with
  - `public struct Tag: Equatable { public let macKey: String; public var name: String; public init(macKey:name:) }`
  - `init(settings: HomeAssistantSettings, password: String?, bridge: String, version: String)`
  - callbacks (main queue): `onStatus: ((String) -> Void)?`, `onConnected: (() -> Void)?`, `onBirth: (() -> Void)?`, `onRemoved: ((PendingRemoval) -> Void)?`
  - `private(set) var connected: Bool`
  - `func start()`, `func publish(tag: Tag, reading: Reading, rssi: Int)`, `func publishConfig(tag: Tag)`, `func remove(_ removal: PendingRemoval)`, `func stop(_ completion: @escaping () -> Void)`
  - internal `func dropConnectionForTesting()`

All state is confined to the main queue, like `MQTTInput`; NIO callbacks hop to main before touching it.

- [ ] **Step 1: Write the loopback test**

Create `Tests/RuuviCoreTests/HomeAssistantPublisherTests.swift`:

```swift
import XCTest
import NIOCore
import MQTTNIO
import RuuviCore
@testable import RuuviMQTT

final class HomeAssistantPublisherTests: XCTestCase {
    func testDiscoveryAvailabilityBirthRemovalAndShutdown() throws {
        guard let portText = ProcessInfo.processInfo.environment["RUUVI_MQTT_TEST_PORT"], let port = Int(portText) else { throw XCTSkip("No test broker supplied") }
        let prefix = "ruuvimac-test-\(UUID().uuidString.prefix(8))"
        let bridge = "0a1b2c3d", key = "c4a1b2d3e4f5"
        let settings = HomeAssistantSettings(host: "127.0.0.1", port: port, prefix: prefix)
        let observer = MQTTClient(host: "127.0.0.1", port: port, identifier: UUID().uuidString, eventLoopGroupProvider: .createNew)
        defer { try? observer.syncShutdownGracefully() }
        var received: [(String, String)] = []
        let lock = NSLock()
        func seen(_ topic: String, _ payload: String) -> Bool { lock.lock(); defer { lock.unlock() }; return received.contains { $0 == (topic, payload) } }
        func count(_ topic: String) -> Int { lock.lock(); defer { lock.unlock() }; return received.filter { $0.0 == topic }.count }
        observer.addPublishListener(named: "t") { result in
            guard case .success(let m) = result else { return }
            var b = m.payload
            lock.lock(); received.append((m.topicName, b.readString(length: b.readableBytes) ?? "")); lock.unlock()
        }
        _ = try observer.connect().wait()
        _ = try observer.subscribe(to: [.init(topicFilter: "\(prefix)/#", qos: .atLeastOnce), .init(topicFilter: "ruuvimac/#", qos: .atLeastOnce)]).wait()

        let availability = HomeAssistantDiscovery.availabilityTopic(bridge: bridge)
        let config = HomeAssistantDiscovery.configTopic(prefix: prefix, macKey: key)
        let publisher = HomeAssistantPublisher(settings: settings, password: nil, bridge: bridge, version: "test")
        let connected = expectation(description: "connected"); connected.assertForOverFulfill = false
        publisher.onConnected = { connected.fulfill() }
        let birth = expectation(description: "birth")
        publisher.onBirth = { birth.fulfill() }
        let removed = expectation(description: "removed")
        publisher.onRemoved = { _ in removed.fulfill() }
        publisher.start()
        wait(for: [connected], timeout: 10)

        let tag = HomeAssistantPublisher.Tag(macKey: key, name: "Sauna")
        publisher.publish(tag: tag, reading: Reading(date: Date(), temperature: 21), rssi: -60)
        let deadline = Date().addingTimeInterval(5)
        while (count(config) == 0 || count(HomeAssistantDiscovery.stateTopic(macKey: key)) == 0) && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(seen(availability, "online"))
        XCTAssertEqual(count(config), 1)
        XCTAssertEqual(count(HomeAssistantDiscovery.stateTopic(macKey: key)), 1)

        _ = try observer.publish(to: HomeAssistantDiscovery.birthTopic(prefix: prefix), payload: ByteBuffer(string: "online"), qos: .atLeastOnce).wait()
        wait(for: [birth], timeout: 5)

        publisher.dropConnectionForTesting()
        let willDeadline = Date().addingTimeInterval(10)
        while !seen(availability, "offline") && Date() < willDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertTrue(seen(availability, "offline"), "Last Will not delivered")

        let reconnected = expectation(description: "reconnected")
        publisher.onConnected = { reconnected.fulfill() }
        wait(for: [reconnected], timeout: 15)
        publisher.remove(PendingRemoval(macKey: key, host: "127.0.0.1", port: port, prefix: prefix))
        wait(for: [removed], timeout: 5)
        XCTAssertTrue(seen(config, ""))

        lock.lock(); received.removeAll(); lock.unlock()
        let stopped = expectation(description: "stopped")
        publisher.stop { stopped.fulfill() }
        wait(for: [stopped], timeout: 5)
        let offDeadline = Date().addingTimeInterval(3)
        while !seen(availability, "offline") && Date() < offDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertTrue(seen(availability, "offline"), "ordered shutdown did not publish offline")
        _ = try observer.publish(to: availability, payload: ByteBuffer(), qos: .atLeastOnce, retain: true).wait()
    }
}
```

Note: `MQTTNIO` re-exports `NIOCore`'s `ByteBuffer`; if `import NIOCore` fails to resolve in the test target, remove it (the existing `MQTTTests` builds payloads with `.init(string:)` and only imports `MQTTNIO`).

- [ ] **Step 2: Run and see it fail**

Run: `swift test --build-system native --filter HomeAssistantPublisherTests`
Expected: compile failure, `cannot find 'HomeAssistantPublisher' in scope`.

- [ ] **Step 3: Implement**

Create `Sources/RuuviMQTT/HomeAssistantPublisher.swift`:

```swift
import Foundation
import MQTTNIO
import NIOCore
import RuuviCore

/// Publishes discovery configs, state and availability to a Home Assistant broker.
/// All state is confined to the main queue; NIO callbacks hop back before use.
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
        guard !stopped else { return }
        onStatus?("Connecting to the Home Assistant broker…")
        let configuration = MQTTClient.Configuration(keepAliveInterval: .seconds(30), connectTimeout: .seconds(10),
            userName: settings.username.isEmpty ? nil : settings.username,
            password: settings.username.isEmpty ? nil : password,
            useSSL: settings.tls, tlsConfiguration: settings.tls ? .ts(TSTLSConfiguration()) : nil)
        let c = MQTTClient(host: settings.host, port: settings.port, identifier: identifier,
                           eventLoopGroupProvider: .createNew, configuration: configuration)
        client = c
        let birthTopic = HomeAssistantDiscovery.birthTopic(prefix: settings.prefix)
        c.addPublishListener(named: "birth") { [weak self, weak c] result in
            guard case .success(let message) = result, message.topicName == birthTopic else { return }
            var buffer = message.payload
            let text = buffer.readString(length: buffer.readableBytes)
            DispatchQueue.main.async {
                guard let self, self.client === c, self.connected, text == "online" else { return }
                self.onBirth?()
            }
        }
        c.addCloseListener(named: "reconnect") { [weak self, weak c] _ in
            DispatchQueue.main.async { self?.failed(c, message: "Home Assistant broker disconnected; reconnecting…") }
        }
        let will = (topicName: availability, payload: ByteBuffer(string: "offline"), qos: MQTTQoS.atLeastOnce, retain: true)
        c.connect(will: will)
            .flatMap { _ in c.publish(to: self.availability, payload: ByteBuffer(string: "online"), qos: .atLeastOnce, retain: true) }
            .flatMap { c.subscribe(to: [.init(topicFilter: birthTopic, qos: .atLeastOnce)]).map { _ in } }
            .whenComplete { [weak self, weak c] result in
                DispatchQueue.main.async {
                    guard let self, self.client === c, !self.stopped else { return }
                    switch result {
                    case .success:
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

    private func failed(_ c: MQTTClient?, message: String) {
        guard let c, client === c, !stopped else { return }
        client = nil; connected = false
        c.removeCloseListener(named: "reconnect"); c.shutdown { _ in }
        onStatus?(message)
        let task = DispatchWorkItem { [weak self] in self?.connect() }
        retry = task; DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
        delay = min(delay * 2, 30)
    }

    public func publishConfig(tag: Tag) {
        guard connected, let c = client else { return }
        let payload = HomeAssistantDiscovery.config(macKey: tag.macKey, name: tag.name, bridge: bridge, version: version)
        configured.insert(tag.macKey)
        c.publish(to: HomeAssistantDiscovery.configTopic(prefix: settings.prefix, macKey: tag.macKey),
                  payload: ByteBuffer(bytes: payload), qos: .atLeastOnce, retain: true)
            .whenFailure { [weak self] _ in DispatchQueue.main.async { self?.configured.remove(tag.macKey) } }
    }

    /// Sends the tag's config first if this connection has not sent it yet, then the state.
    public func publish(tag: Tag, reading: Reading, rssi: Int) {
        guard connected, let c = client else { return }
        if !configured.contains(tag.macKey) { publishConfig(tag: tag) }
        c.publish(to: HomeAssistantDiscovery.stateTopic(macKey: tag.macKey),
                  payload: ByteBuffer(bytes: HomeAssistantDiscovery.state(reading, rssi: rssi)), qos: .atMostOnce)
            .whenFailure { _ in }
    }

    /// Empty retained config at QoS 1. `onRemoved` fires only after the broker acknowledges it.
    public func remove(_ removal: PendingRemoval) {
        guard connected, let c = client, removal.brokerKey == settings.brokerKey else { return }
        configured.remove(removal.macKey)
        c.publish(to: HomeAssistantDiscovery.configTopic(prefix: removal.prefix, macKey: removal.macKey),
                  payload: ByteBuffer(), qos: .atLeastOnce, retain: true)
            .whenSuccess { [weak self] in DispatchQueue.main.async { self?.onRemoved?(removal) } }
    }

    /// Ordered shutdown: stop retries, publish retained offline and wait for the ack, disconnect, shut down.
    /// If any step fails the broker's Last Will marks this bridge offline. Completion runs on main.
    public func stop(_ completion: @escaping () -> Void) {
        stopped = true; retry?.cancel(); retry = nil
        let wasConnected = connected
        connected = false
        guard let c = client else { completion(); return }
        client = nil
        c.removeCloseListener(named: "reconnect")
        let finish = { c.shutdown { _ in DispatchQueue.main.async(execute: completion) } }
        guard wasConnected, c.isActive() else { finish(); return }
        c.publish(to: availability, payload: ByteBuffer(string: "offline"), qos: .atLeastOnce, retain: true)
            .flatMap { c.disconnect() }
            .whenComplete { _ in finish() }
    }

    /// Closes the socket without DISCONNECT so the broker sends the Last Will; the reconnect logic then runs.
    func dropConnectionForTesting() {
        client?.shutdown { _ in }
    }
}
```

`ByteBuffer(bytes:)` takes a `Sequence` of `UInt8`; `Data` conforms. If the compiler requires it, use `ByteBuffer(bytes: [UInt8](payload))`.

- [ ] **Step 4: Build and run**

Run: `swift build --build-system native` (must compile cleanly).
Run: `swift test --build-system native --filter HomeAssistantPublisherTests`. Without `RUUVI_MQTT_TEST_PORT` the test is skipped. If a broker is available on 127.0.0.1 (for example `mosquitto -p 18884`), run `RUUVI_MQTT_TEST_PORT=18884 swift test --build-system native --filter HomeAssistantPublisherTests` and expect it to pass. Do not install a broker; if none is available, record "loopback not run, no broker" in the report.

- [ ] **Step 5: Full suite, commit**

```bash
git add Sources/RuuviMQTT/HomeAssistantPublisher.swift Tests/RuuviCoreTests/HomeAssistantPublisherTests.swift
git commit -m "Add Home Assistant MQTT publisher with Last Will, birth handling and ordered shutdown"
```

---

### Task 5: Bridge controller and app wiring

**Files:**
- Create: `Sources/RuuviMac/HomeAssistantBridge.swift`
- Modify: `Sources/RuuviMac/SensorStore.swift` (reading source, callbacks)
- Modify: `Sources/RuuviMac/AppDelegate.swift` (own the bridge, wire callbacks, deferred termination)

**Interfaces:**
- Consumes: Tasks 1 to 4. `SensorStore.receive(id:reading:rssi:)`, `rename(_:to:)`. `AppDelegate.applicationShouldTerminate`.
- Produces:
  - `SensorStore`: `receive(id:reading:rssi:source:)`, `var onReading: ((Sensor, Reading, Int, ReadingSource) -> Void)?`, `var onRename: ((Sensor) -> Void)?`
  - `final class HomeAssistantBridge: ObservableObject` with published `status: String`, `enabled: Bool`, `settings: HomeAssistantSettings`, `ledger: HomeAssistantLedger`, `hasPassword: Bool`, `keychainProblem: Bool`, `connected: Bool`; methods `start()`, `apply(settings:enabled:password:clearPassword:) -> String?` (returns a validation error or nil), `receive(sensor:reading:rssi:source:)`, `renamed(_:)`, `macKey(for:) -> String?`, `isPublishing(_ id: String) -> Bool`, `isRemovalPending(_ id: String) -> Bool`, `setPublishing(_ id: String, _ on: Bool)`, `remove(_ id: String)`, `removeAll()`, `retryKeychain()`, `shutdown(_:)`.
  - `AppDelegate.homeAssistant: HomeAssistantBridge`.

No unit tests: this is glue around the tested router, ledger and publisher. Verification is build plus Task 8.

- [ ] **Step 1: Reading source in `SensorStore`**

In `Sources/RuuviMac/SensorStore.swift`:

Add below `@Published var savingPaused = false`:

```swift
    /// Called on main after a reading is accepted. The Home Assistant bridge filters by source.
    var onReading: ((Sensor, Reading, Int, ReadingSource) -> Void)?
    var onRename: ((Sensor) -> Void)?
```

In `useMQTT(_:)`, change the reading callback to pass the source:

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

In `rename(_:to:)`, after `persist()` add `onRename?(sensors[i])`:

```swift
        sensors[i].name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)); persist()
        onRename?(sensors[i])
```

Search the target for other `receive(id:` callers (`grep -n "receive(id:" Sources`) and add `source:` to each; there should be none besides the two above.

- [ ] **Step 2: Bridge controller**

Create `Sources/RuuviMac/HomeAssistantBridge.swift`:

```swift
import Foundation
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
    let bridgeID: String
    private let defaults: UserDefaults
    private let keychain = KeychainPasswordStore()
    private let keychainQueue = DispatchQueue(label: "org.ruuvimac.keychain")
    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    private var publisher: HomeAssistantPublisher?
    private var router = HomeAssistantRouter()
    private var seen: [String: HomeAssistantPublisher.Tag] = [:]
    /// Increments whenever the publisher is replaced, so late Keychain results for an old configuration are ignored.
    private var generation = 0

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

    func start() {
        generation += 1
        let current = generation
        guard enabled else { status = "Home Assistant publishing is off"; return }
        guard settings.validationError == nil else { status = settings.validationError!; return }
        guard !settings.username.isEmpty, hasPassword else { connect(password: nil); return }
        status = "Reading the broker password from the Keychain…"
        let account = settings.account, store = keychain
        keychainQueue.async {
            let result = Result { try store.read(account: account) }
            DispatchQueue.main.async {
                guard current == self.generation else { return }
                switch result {
                case .success(let password): self.keychainProblem = false; self.connect(password: password)
                case .failure(let error):
                    self.keychainProblem = true
                    self.status = "Password unavailable from Keychain: " + ((error as? KeychainError)?.message ?? error.localizedDescription)
                }
            }
        }
    }

    func retryKeychain() { start() }

    private func connect(password: String?) {
        let p = HomeAssistantPublisher(settings: settings, password: password, bridge: bridgeID, version: version)
        p.onStatus = { [weak self] text in self?.status = text }
        p.onConnected = { [weak self, weak p] in
            guard let self, let p else { return }
            self.connected = true
            self.router.throttle.resetAll()
            for removal in self.ledger.pendingRemovals(for: self.settings) { p.remove(removal) }
        }
        p.onBirth = { [weak self, weak p] in
            guard let self, let p else { return }
            self.router.throttle.resetAll()
            for tag in self.seen.values where self.ledger.isPublishing(tag.macKey, publishNewTags: self.settings.publishNewTags) {
                p.publishConfig(tag: tag)
            }
        }
        p.onRemoved = { [weak self] removal in
            self?.ledger.completeRemoval(removal); self?.saveLedger()
        }
        publisher = p
        p.start()
    }

    /// Stops the current publisher in order. Completion runs on main.
    func shutdown(_ completion: @escaping () -> Void) {
        generation += 1
        connected = false
        guard let p = publisher else { completion(); return }
        publisher = nil
        p.stop(completion)
    }

    /// Validates, stores settings and password, then restarts the publisher. Returns an error message or nil.
    func apply(settings new: HomeAssistantSettings, enabled newEnabled: Bool, password: String, clearPassword: Bool) -> String? {
        if newEnabled, let problem = new.validationError { return problem }
        let accountChanged = new.account != settings.account
        if !new.username.isEmpty, hasPassword, accountChanged, password.isEmpty, !clearPassword {
            return "Enter the password again for the new username, host or port."
        }
        let oldAccount = settings.account
        let hadPassword = hasPassword
        settings = new; enabled = newEnabled
        defaults.set(try? JSONEncoder().encode(new), forKey: "ha.settings")
        defaults.set(newEnabled, forKey: "ha.enabled")
        let store = keychain
        let restart = { [weak self] in self?.shutdown { self?.start() } }
        if clearPassword || new.username.isEmpty {
            hasPassword = false; defaults.set(false, forKey: "ha.hasPassword")
            keychainQueue.async {
                if hadPassword { try? store.delete(account: oldAccount) }
                DispatchQueue.main.async(execute: restart)
            }
        } else if !password.isEmpty {
            let account = new.account
            keychainQueue.async {
                let result = Result { try store.save(password, account: account) }
                if case .success = result, hadPassword, oldAccount != account { try? store.delete(account: oldAccount) }
                DispatchQueue.main.async {
                    switch result {
                    case .success: self.hasPassword = true; self.defaults.set(true, forKey: "ha.hasPassword")
                    case .failure(let error):
                        self.status = "Could not save the password: " + ((error as? KeychainError)?.message ?? error.localizedDescription)
                    }
                    restart()
                }
            }
        } else {
            restart()
        }
        return nil
    }

    func receive(sensor: Sensor, reading: Reading, rssi: Int, source: ReadingSource) {
        guard let p = publisher, let key = router.route(id: sensor.id, source: source, connected: p.connected,
                                                         ledger: ledger, publishNewTags: settings.publishNewTags, now: Date())
        else { return }
        let tag = HomeAssistantPublisher.Tag(macKey: key, name: sensor.name)
        seen[key] = tag
        p.publish(tag: tag, reading: reading, rssi: rssi)
        if ledger.markPublished(key, brokerKey: settings.brokerKey) { saveLedger() }
    }

    func renamed(_ sensor: Sensor) {
        guard let key = HomeAssistantDiscovery.macKey(sensor.id), var tag = seen[key],
              ledger.isPublishing(key, publishNewTags: settings.publishNewTags) else { return }
        tag.name = sensor.name; seen[key] = tag
        publisher?.publishConfig(tag: tag)
    }

    func macKey(for id: String) -> String? { HomeAssistantDiscovery.macKey(id) }
    func isPublishing(_ id: String) -> Bool {
        macKey(for: id).map { ledger.isPublishing($0, publishNewTags: settings.publishNewTags) } ?? false
    }
    func isRemovalPending(_ id: String) -> Bool { macKey(for: id).map(ledger.isRemovalPending) ?? false }

    func setPublishing(_ id: String, _ on: Bool) {
        guard let key = macKey(for: id), !ledger.isRemovalPending(key) else { return }
        ledger.setPublishing(key, on); saveLedger()
        if on { router.throttle.reset(key) }
    }

    func remove(_ id: String) {
        guard let key = macKey(for: id) else { return }
        let removal = ledger.queueRemoval(key, settings: settings); saveLedger()
        seen[key] = nil
        publisher?.remove(removal)
    }

    func removeAll() {
        let removals = ledger.queueRemoveAll(settings: settings); saveLedger()
        for removal in removals { seen[removal.macKey] = nil; publisher?.remove(removal) }
    }

    private func saveLedger() { defaults.set(try? JSONEncoder().encode(ledger), forKey: "ha.ledger") }
}
```

Note: `connected` mirrors the publisher only for UI and quit decisions; it is set true in `onConnected` and false in `shutdown`. When the publisher drops and reconnects, its `onStatus` text shows the state; `connected` stays true until shutdown, which is acceptable because `stop` handles a dead client without waiting.

- [ ] **Step 3: App delegate wiring**

In `Sources/RuuviMac/AppDelegate.swift`:

Add `let homeAssistant = HomeAssistantBridge()` after `let loginItem = LoginItem()`.

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
        // Publish retained offline before quitting, but never hold quit for more than 2 seconds.
        var replied = false
        let reply = {
            guard !replied else { return }
            replied = true
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        homeAssistant.shutdown(reply)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: reply)
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
- Produces: `struct HomeAssistantSettingsView: View` with `init(bridge: HomeAssistantBridge)`; `SelectionModel.showHomeAssistant: Bool`; `ContentView(store:selection:loginItem:homeAssistant:)`; `SensorDetail(sensor:store:homeAssistant:)`; `MenuBarView(store:selection:loginItem:homeAssistant:delegate:)`.

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
                SecureField(bridge.hasPassword ? "Password (leave empty to keep the saved one)" : "Password", text: $password)
                if bridge.hasPassword { Toggle("Remove the saved password", isOn: $clearPassword) }
                TextField("Discovery prefix", text: $prefix)
                Toggle("Publish newly discovered tags", isOn: $publishNewTags)
            }
            Text("Publish each tag from one Mac only. Turn off publishing for a tag on the other Macs. Changing the broker or prefix leaves devices on the old broker; remove them first.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Circle().fill(bridge.connected ? Color.green : Color.secondary).frame(width: 7, height: 7)
                Text(bridge.status).font(.caption)
                if bridge.keychainProblem { Button("Try again") { bridge.retryKeychain() } }
            }
            if let issue { Text(issue).foregroundStyle(.red) }
            HStack {
                Button("Remove all devices from this broker…") { confirmRemoveAll = true }
                    .disabled(!bridge.enabled)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    let settings = HomeAssistantSettings(host: host.trimmingCharacters(in: .whitespacesAndNewlines), port: port,
                        tls: tls, username: username, prefix: prefix.trimmingCharacters(in: .whitespacesAndNewlines),
                        publishNewTags: publishNewTags)
                    if let problem = bridge.apply(settings: settings, enabled: enabled, password: password, clearPassword: clearPassword) {
                        issue = problem
                    } else { dismiss() }
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 540)
        .onAppear {
            let s = bridge.settings
            enabled = bridge.enabled; host = s.host; port = s.port; tls = s.tls; username = s.username
            prefix = s.prefix; publishNewTags = s.publishNewTags
        }
        .confirmationDialog("Remove every device this Mac published to this broker from Home Assistant?",
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

- `RuuviMacApp`: pass `homeAssistant: delegate.homeAssistant` to `ContentView`, and `homeAssistant: delegate.homeAssistant` to `MenuBarView` (argument order `store:selection:loginItem:homeAssistant:delegate:`).
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
                    }
                    Text("Turning publishing off keeps the device in Home Assistant so another Mac can publish it. Remove deletes the device.")
                        .font(.caption).foregroundStyle(.secondary)
                }
```

- [ ] **Step 4: Menu**

In `Sources/RuuviMac/MenuBarView.swift`: add `@ObservedObject var homeAssistant: HomeAssistantBridge` after `loginItem` (so the memberwise init order is `store, selection, loginItem, homeAssistant, delegate`). After `Text(store.status)` add:

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

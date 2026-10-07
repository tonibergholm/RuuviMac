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

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

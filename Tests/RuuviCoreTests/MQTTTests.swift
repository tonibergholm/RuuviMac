import XCTest
import RuuviCore
import RuuviMQTT
import MQTTNIO

final class MQTTTests: XCTestCase {
    let raw = "0201061BFF99040512FC5394C37C0004FFFC040CAC364200CDCBB8334C884F"
    func data(_ obj: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: obj) }
    func testGatewayAndDynamicAdvertisementOffsets() throws {
        let obj: [String: Any] = ["data": raw, "ts": "100000", "rssi": -60]
        let sample = try XCTUnwrap(MQTTMessageDecoder.decode(data(obj), topic: "ruuvi/tag", now: Date(timeIntervalSince1970: 100001)))
        XCTAssertEqual(sample.identity, "CB:B8:33:4C:88:4F")
        XCTAssertEqual(sample.reading.temperature!, 24.3, accuracy: 0.001)
        XCTAssertEqual(sample.reading.pressure!, 1000.44, accuracy: 0.001)
        XCTAssertEqual(sample.reading.date.timeIntervalSince1970, 100000)
        let shifted: [String: Any] = ["data": "0303AAFE" + raw.dropFirst(6), "ts": 100000, "rssi": -60]
        XCTAssertEqual(MQTTMessageDecoder.decode(try data(shifted), topic: "tag", now: Date(timeIntervalSince1970: 100001))?.reading.temperature, 24.3)
    }
    func testBridgePressureConversionAndIdentity() throws {
        let obj: [String: Any] = ["data_format":5,"mac":"cbb8334c884f","timestamp":100000,"rssi":-70,"temperature":24.3,"pressure":100044]
        let sample = try XCTUnwrap(MQTTMessageDecoder.decode(data(obj), topic: "ruuvi/tag", now: Date(timeIntervalSince1970: 100001)))
        XCTAssertEqual(sample.identity, "CB:B8:33:4C:88:4F")
        XCTAssertEqual(sample.reading.pressure!, 1000.44, accuracy: 0.001)
        XCTAssertNil(sample.reading.sequence)
    }
    func testMalformedStatusAndFutureMessages() throws {
        let now = Date(timeIntervalSince1970: 100001)
        for payload in [Data("bad json".utf8), Data("[]".utf8), try data(["state":"online"]),
            try data(["data":raw,"ts":"NaN","rssi":-60]), try data(["data":raw,"ts":100400,"rssi":-60]),
            try data(["data":"FF","ts":100000,"rssi":-60]), try data(["data":raw,"ts":100000,"rssi":true])] {
            XCTAssertNil(MQTTMessageDecoder.decode(payload, topic: "tag", now: now))
        }
        XCTAssertNil(MQTTMessageDecoder.decode(Data(repeating: 65, count: 65537), topic: "tag"))
    }
    func testSettingsFilters() {
        for topic in ["a/#/b","abc+","#foo","","a\0b"] { XCTAssertNotNil(MQTTSettings(host: "localhost", topic: topic).validationError) }
        XCTAssertNil(MQTTSettings(host: "localhost", topic: "ruuvi/+/data").validationError)
        XCTAssertNotNil(MQTTSettings(host: "localhost", port: 0).validationError)
    }
    func testRealBrokerGatewayAndBridge() throws {
        guard let portText = ProcessInfo.processInfo.environment["RUUVI_MQTT_TEST_PORT"], let port = Int(portText) else { throw XCTSkip("No test broker supplied") }
        let topic = "ruuvimac-test/CB:B8:33:4C:88:4F"
        let input = MQTTInput(settings: MQTTSettings(host: "127.0.0.1", port: port, topic: "ruuvimac-test/#"))
        let subscribed = expectation(description: "subscribed")
        let rawReceived = expectation(description: "gateway reading")
        let bridgeReceived = expectation(description: "bridge reading")
        var didSubscribe = false
        let timestamp = Date().timeIntervalSince1970 - 90
        input.onStatus = { status in
            if status.hasPrefix("MQTT subscribed"), !didSubscribe { didSubscribe = true; subscribed.fulfill() }
        }
        input.onReading = { sample in
            XCTAssertEqual(sample.identity, "CB:B8:33:4C:88:4F")
            if sample.reading.temperature == 24.3 {
                XCTAssertEqual(sample.reading.date.timeIntervalSince1970, timestamp, accuracy: 0.01)
                rawReceived.fulfill()
            } else if sample.reading.temperature == 28 {
                XCTAssertEqual(sample.reading.pressure, 1000)
                bridgeReceived.fulfill()
            }
        }
        input.start()
        defer { input.stop() }
        wait(for: [subscribed], timeout: 10)
        let publisher = MQTTClient(host: "127.0.0.1", port: port, identifier: UUID().uuidString, eventLoopGroupProvider: .createNew)
        defer { publisher.shutdown { _ in } }
        let ready = expectation(description: "publisher ready")
        publisher.connect().whenComplete { result in
            if case .failure(let error) = result { XCTFail(String(describing: error)) }
            ready.fulfill()
        }
        wait(for: [ready], timeout: 10)
        let payload = String(data: try data(["data":raw,"ts":timestamp,"rssi":-60]), encoding: .utf8)!
        publisher.publish(to: topic, payload: .init(string: payload), qos: .atLeastOnce, retain: true).whenFailure { XCTFail(String(describing: $0)) }
        wait(for: [rawReceived], timeout: 10)
        let bridge = String(data: try data(["data_format":5,"mac":"CB:B8:33:4C:88:4F","timestamp":Date().timeIntervalSince1970,"rssi":-50,"temperature":28,"pressure":100000]), encoding: .utf8)!
        publisher.publish(to: topic, payload: .init(string: bridge), qos: .atLeastOnce).whenFailure { XCTFail(String(describing: $0)) }
        wait(for: [bridgeReceived], timeout: 10)
        publisher.publish(to: topic, payload: .init(), qos: .atLeastOnce, retain: true).whenFailure { XCTFail(String(describing: $0)) }
    }
}

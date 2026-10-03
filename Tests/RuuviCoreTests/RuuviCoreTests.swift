import XCTest
@testable import RuuviCore
final class RuuviCoreTests: XCTestCase {
    func packet(_ hex: String) -> Data {
        let chars = Array(hex)
        return Data(stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0...$0+1]), radix: 16)! })
    }
    func decode(_ hex: String) -> DecodedTag? {
        AdvertisementDecoder.decode(packet("9904" + hex), peripheralID: "test", rssi: -60)
    }
    func testOfficialValidVector() throws {
        let tag = try XCTUnwrap(decode("0512FC5394C37C0004FFFC040CAC364200CDCBB8334C884F"))
        XCTAssertEqual(tag.mac, "CB:B8:33:4C:88:4F")
        XCTAssertEqual(try XCTUnwrap(tag.reading.temperature), 24.3, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(tag.reading.humidity), 53.49, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(tag.reading.pressure), 1000.44, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(tag.reading.voltage), 2.977, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(tag.reading.accelerationY), -0.004, accuracy: 0.001)
        XCTAssertEqual(tag.reading.sequence, 205)
        XCTAssertEqual(tag.reading.txPower, 4)
        XCTAssertEqual(tag.reading.movement, 66)
    }
    func testOfficialSentinels() throws {
        let tag = try XCTUnwrap(decode("058000FFFFFFFF800080008000FFFFFFFFFFFFFFFFFFFFFF"))
        XCTAssertNil(tag.mac)
        XCTAssertNil(tag.reading.temperature); XCTAssertNil(tag.reading.humidity)
        XCTAssertNil(tag.reading.pressure); XCTAssertNil(tag.reading.voltage)
        XCTAssertNil(tag.reading.accelerationX); XCTAssertNil(tag.reading.movement)
        XCTAssertNil(tag.reading.sequence); XCTAssertNil(tag.reading.txPower)
    }
    func testOfficialExtremes() throws {
        let max = try XCTUnwrap(decode("057FFFFFFEFFFE7FFF7FFF7FFFFFDEFEFFFECBB8334C884F"))
        XCTAssertEqual(try XCTUnwrap(max.reading.temperature), 163.835, accuracy: 0.001)
        let min = try XCTUnwrap(decode("058001000000008001800180010000000000CBB8334C884F"))
        XCTAssertEqual(try XCTUnwrap(min.reading.temperature), -163.835, accuracy: 0.001)
        XCTAssertEqual(min.reading.pressure, 500)
    }
    func testRejectsMalformedAndOtherManufacturers() {
        let valid = packet("99040512FC5394C37C0004FFFC040CAC364200CDCBB8334C884F")
        for length in 0..<valid.count {
            XCTAssertNil(AdvertisementDecoder.decode(Data(valid.prefix(length)), peripheralID: "x", rssi: 0))
        }
        var wrong = valid; wrong[0] = 0
        XCTAssertNil(AdvertisementDecoder.decode(wrong, peripheralID: "x", rssi: 0))
        wrong = valid; wrong[2] = 6
        XCTAssertNil(AdvertisementDecoder.decode(wrong, peripheralID: "x", rssi: 0))
    }
    func testHistoryDeduplicationRetentionAndPersistence() throws {
        var r = try XCTUnwrap(decode("0512FC5394C37C0004FFFC040CAC364200CDCBB8334C884F")).reading
        r.date = Date(timeIntervalSince1970: 100000)
        var sensor = Sensor(id: "tag", date: r.date, rssi: -50, reading: r)
        sensor.receive(r, rssi: -50)
        r.date.addTimeInterval(61); sensor.receive(r, rssi: -60)
        XCTAssertEqual(sensor.history.count, 1)
        r.sequence = 206; sensor.receive(r, rssi: -70)
        XCTAssertEqual(sensor.history.count, 2)
        r.date.addTimeInterval(86401); r.sequence = 207; sensor.receive(r, rssi: -50)
        XCTAssertEqual(sensor.history.count, 1)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let archive = SensorArchive(url: folder.appendingPathComponent("sensors.json"))
        XCTAssertTrue(try archive.load().isEmpty)
        sensor.name = "Kitchen"; sensor.favorite = true
        try archive.save([sensor])
        let loaded = try XCTUnwrap(archive.load().first)
        XCTAssertEqual(loaded.name, "Kitchen"); XCTAssertTrue(loaded.favorite)
        XCTAssertEqual(loaded.history, sensor.history)
    }
}

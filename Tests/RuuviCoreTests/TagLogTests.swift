import XCTest
@testable import RuuviCore
final class TagLogTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1567047917)
    func packet(_ field: UInt8, _ stamp: UInt32, _ value: UInt32) -> Data {
        var d=Data([0x3A,field,0x10])
        for n in [stamp,value] { d.append(contentsOf: [UInt8(n>>24),UInt8(truncatingIfNeeded:n>>16),UInt8(truncatingIfNeeded:n>>8),UInt8(truncatingIfNeeded:n)]) }
        return d
    }
    func testOfficialRequestAndSignedValues() throws {
        let acc=TagLogAccumulator(now:now,start:Date(timeIntervalSince1970:1566047917))
        XCTAssertEqual(acc.request,Data([0x3A,0x3A,0x11,0x5D,0x67,0x40,0xED,0x5D,0x57,0xFE,0xAD]))
        try acc.feed(packet(0x32,1567047916,100044));try acc.feed(packet(0x30,1567047916,UInt32(bitPattern: -1876)));try acc.feed(packet(0x31,1567047916,2445))
        let r=try XCTUnwrap(acc.readings.first)
        XCTAssertEqual(r.temperature,-18.76);XCTAssertEqual(r.humidity,24.45);XCTAssertEqual(r.pressure,1000.44)
        try acc.feed(Data([0x3A,0x3A,0x10]+Array(repeating:255,count:8)));XCTAssertTrue(acc.complete)
    }
    func testGroupingPartialSentinelsAndBadPackets() throws {
        let acc=TagLogAccumulator(now:now)
        try acc.feed(packet(0x30,1567047800,2000));try acc.feed(packet(0x31,1567047810,5000))
        try acc.feed(packet(0x30,1567048000,2100));try acc.feed(packet(0x30,1567047900,0x80000000))
        XCTAssertEqual(acc.count,2);XCTAssertNil(acc.readings[0].humidity)
        XCTAssertThrowsError(try acc.feed(Data([0x3A,0x30,0x10,0])))
        XCTAssertThrowsError(try acc.feed(Data([0x3A,0x3A,0xF0]+Array(repeating:255,count:8))))
    }
    func testMergePreservesLiveReadingAndMinuteDeduplication() throws {
        let live=Reading(date:now,temperature:24,humidity:50,pressure:1000)
        var sensor=Sensor(id:"tag",date:now,rssi:-50,reading:live)
        sensor.receive(live,rssi:-50);sensor.name="Kitchen";sensor.favorite=true
        let old=Reading(date:now.addingTimeInterval(-3*86400),temperature:18)
        XCTAssertEqual(sensor.mergeHistory([old],now:now),1)
        var partial=old;partial.date.addTimeInterval(1);partial.humidity=45
        XCTAssertEqual(sensor.mergeHistory([partial],now:now),0)
        XCTAssertEqual(sensor.history.count,2);XCTAssertEqual(sensor.history[0].humidity,45)
        XCTAssertEqual(sensor.latest,live);XCTAssertEqual(sensor.lastSeen,now)
        XCTAssertEqual(sensor.name,"Kitchen");XCTAssertTrue(sensor.favorite)
        XCTAssertEqual(sensor.mergeHistory([Reading(date:now.addingTimeInterval(-TagLogAccumulator.retention-1),temperature:0)],now:now),0)
    }
}

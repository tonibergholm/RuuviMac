import XCTest
@testable import RuuviCore

final class ArchiveGuardTests: XCTestCase {
    var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }
    func sensor() -> Sensor {
        Sensor(id: "AA:BB:CC:DD:EE:FF", date: Date(timeIntervalSince1970: 1_000), rssi: -60,
               reading: Reading(date: Date(timeIntervalSince1970: 1_000), temperature: 20))
    }

    func testMissingFileLoadsEmptyAndStaysWritable() throws {
        let archive = GuardedArchive(url: dir.appendingPathComponent("sensors.json"))
        XCTAssertEqual(try archive.load().get().count, 0)
        XCTAssertTrue(archive.writable)
        XCTAssertTrue(try archive.save([sensor()]))
        XCTAssertEqual(try archive.load().get().count, 1)
    }

    func testFailedLoadBlocksSavesAndKeepsOriginalBytes() throws {
        let url = dir.appendingPathComponent("sensors.json")
        let garbage = Data("{not json".utf8)
        try garbage.write(to: url)
        let archive = GuardedArchive(url: url)
        guard case .failure = archive.load() else { return XCTFail("expected load failure") }
        XCTAssertFalse(archive.writable)
        XCTAssertFalse(try archive.save([sensor()]))
        XCTAssertEqual(try Data(contentsOf: url), garbage)
    }

    func testMoveAsideKeepsOldFileAndReenablesSaving() throws {
        let url = dir.appendingPathComponent("sensors.json")
        let garbage = Data("{not json".utf8)
        try garbage.write(to: url)
        let archive = GuardedArchive(url: url)
        _ = archive.load()
        let moved = try archive.moveAside(now: Date(timeIntervalSince1970: 1_791_370_000))
        XCTAssertEqual(moved.lastPathComponent, "sensors.json.unreadable-1791370000")
        XCTAssertEqual(try Data(contentsOf: moved), garbage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(archive.writable)
        XCTAssertTrue(try archive.save([sensor()]))
        XCTAssertEqual(try archive.load().get().first?.id, "AA:BB:CC:DD:EE:FF")
    }
}

import XCTest
@testable import RuuviCore

final class MenuSelectionTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 10_000)
    func sensor(_ id: String, _ name: String, favorite: Bool = false, age: TimeInterval = 0, temperature: Double? = 21) -> Sensor {
        let date = now.addingTimeInterval(-age)
        var s = Sensor(id: id, date: date, rssi: -60, reading: Reading(date: date, temperature: temperature, humidity: 40))
        s.name = name; s.favorite = favorite
        return s
    }

    func testFavoritesOnlyWhenAnyExist() {
        let result = MenuSelection.rows([sensor("1", "Attic"), sensor("2", "Sauna", favorite: true)], now: now)
        XCTAssertEqual(result.rows.map(\.id), ["2"])
        XCTAssertEqual(result.overflow, 0)
    }

    func testAllTagsSortedByNameWhenNoFavorites() {
        let result = MenuSelection.rows([sensor("1", "sauna"), sensor("2", "Attic"), sensor("3", "Tag 10"), sensor("4", "Tag 9")], now: now)
        XCTAssertEqual(result.rows.map(\.name), ["Attic", "sauna", "Tag 9", "Tag 10"])
    }

    func testSidebarOrderPutsFavoritesFirst() {
        let sorted = [sensor("1", "Attic"), sensor("2", "Zoo", favorite: true)].sorted(by: MenuSelection.sidebarOrder)
        XCTAssertEqual(sorted.map(\.id), ["2", "1"])
    }

    func testCapAndOverflow() {
        let sensors = (0..<11).map { sensor("\($0)", String(format: "Tag %02d", $0), favorite: true) }
        let result = MenuSelection.rows(sensors, now: now)
        XCTAssertEqual(result.rows.count, 8)
        XCTAssertEqual(result.overflow, 3)
        XCTAssertEqual(result.rows.first?.name, "Tag 00")
    }

    func testStaleBoundary() {
        XCTAssertFalse(MenuSelection.isStale(sensor("1", "A", age: 30), now: now))
        XCTAssertTrue(MenuSelection.isStale(sensor("1", "A", age: 30.5), now: now))
        let rows = MenuSelection.rows([sensor("1", "A", age: 31), sensor("2", "B", age: 5)], now: now).rows
        XCTAssertEqual(rows.map(\.stale), [true, false])
    }

    func testEmptyAndMissingValues() {
        XCTAssertTrue(MenuSelection.rows([], now: now).rows.isEmpty)
        let row = MenuSelection.rows([sensor("1", "A", temperature: nil)], now: now).rows[0]
        XCTAssertNil(row.temperature)
        XCTAssertEqual(row.humidity, 40)
    }
}

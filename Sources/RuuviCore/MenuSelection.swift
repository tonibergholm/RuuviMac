import Foundation

public struct MenuRow: Equatable, Identifiable {
    public let id: String
    public let name: String
    public let temperature: Double?
    public let humidity: Double?
    public let stale: Bool
}

/// Tag rows for the menu bar extra: favorites, or every tag when there are none, in sidebar order.
public enum MenuSelection {
    public static let defaultLimit = 8
    public static let staleAfter: TimeInterval = 30
    public static func sidebarOrder(_ a: Sensor, _ b: Sensor) -> Bool {
        if a.favorite != b.favorite { return a.favorite }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
    public static func isStale(_ sensor: Sensor, now: Date) -> Bool {
        now.timeIntervalSince(sensor.lastSeen) > staleAfter
    }
    public static func rows(_ sensors: [Sensor], now: Date, limit: Int = defaultLimit) -> (rows: [MenuRow], overflow: Int) {
        let favorites = sensors.filter(\.favorite)
        let chosen = (favorites.isEmpty ? sensors : favorites).sorted(by: sidebarOrder)
        let rows = chosen.prefix(limit).map {
            MenuRow(id: $0.id, name: $0.name, temperature: $0.latest.temperature,
                    humidity: $0.latest.humidity, stale: isStale($0, now: now))
        }
        return (rows, max(0, chosen.count - limit))
    }
}

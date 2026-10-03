import Foundation
import CoreBluetooth
import BTKit

public struct Reading: Codable, Equatable, Identifiable {
    public var id: UUID = UUID()
    public var date: Date
    public var temperature: Double?
    public var humidity: Double?
    public var pressure: Double?
    public var voltage: Double?
    public var accelerationX: Double?
    public var accelerationY: Double?
    public var accelerationZ: Double?
    public var movement: Int?
    public var sequence: Int?
    public var txPower: Int?
}

public struct DecodedTag {
    public let mac: String?
    public let reading: Reading
}

/// CoreBluetooth supplies company ID followed by the RAWv2 payload.
/// Strict framing protects BTKit from truncated packets. RAWv2 only in this MVP.
public enum AdvertisementDecoder {
    public static func decode(_ data: Data, peripheralID: String, rssi: Int, date: Date = Date()) -> DecodedTag? {
        let bytes = [UInt8](data)
        guard bytes.count == 26, bytes[0] == 0x99, bytes[1] == 0x04, bytes[2] == 5 else { return nil }
        let device = RuuviDecoderiOS().decodeAdvertisement(uuid: peripheralID, rssi: NSNumber(value: rssi),
            advertisementData: [CBAdvertisementDataManufacturerDataKey: data], isConnected: false, supportsExtendedAdv: false)
        guard case let .ruuvi(.tag(.v5(tag))) = device else { return nil }
        let mac = bytes[20...25].allSatisfy { $0 == 255 } ? nil : bytes[20...25].map { String(format: "%02X", $0) }.joined(separator: ":")
        return DecodedTag(mac: mac, reading: Reading(date: date, temperature: tag.temperature,
            humidity: tag.humidity, pressure: tag.pressure, voltage: tag.voltage,
            accelerationX: tag.accelerationX, accelerationY: tag.accelerationY, accelerationZ: tag.accelerationZ,
            movement: tag.movementCounter, sequence: tag.measurementSequenceNumber, txPower: tag.txPower))
    }
}

public struct Sensor: Codable, Identifiable {
    public var id: String
    public var name: String
    public var favorite: Bool = false
    public var lastSeen: Date
    public var rssi: Int
    public var latest: Reading
    public var history: [Reading] = []
    public init(id: String, date: Date, rssi: Int, reading: Reading) {
        self.id = id; name = "Ruuvi " + String(id.suffix(5)); lastSeen = date
        self.rssi = rssi; latest = reading
    }
    public mutating func receive(_ reading: Reading, rssi: Int) {
        lastSeen = reading.date; self.rssi = rssi; latest = reading
        // At most one sample per minute; do not store repeat transmissions.
        if let last = history.last {
            if reading.date.timeIntervalSince(last.date) < 60 { return }
            if let sequence = reading.sequence, sequence == last.sequence { return }
        }
        history.append(reading)
        history.removeAll { reading.date.timeIntervalSince($0.date) > 86400 }
        if history.count > 1440 { history.removeFirst(history.count - 1440) }
    }
}

public struct SensorArchive {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> [Sensor] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([Sensor].self, from: Data(contentsOf: url))
    }
    public func save(_ sensors: [Sensor]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(sensors).write(to: url, options: .atomic)
    }
}

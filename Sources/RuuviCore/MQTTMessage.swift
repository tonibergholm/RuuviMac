import Foundation
import CoreFoundation

public struct MQTTReading {
    public let identity: String
    public let reading: Reading
    public let rssi: Int
}

public enum MQTTMessageDecoder {
    public static func mac(_ value: String?) -> String? {
        guard let value else { return nil }
        let compact = value.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "").uppercased()
        guard compact.count == 12, compact.allSatisfy({ "0123456789ABCDEF".contains($0) }) else { return nil }
        let chars = Array(compact)
        return stride(from: 0, to: 12, by: 2).map { String(chars[$0...$0+1]) }.joined(separator: ":")
    }
    private static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
        let n: Double?
        if let value = value as? NSNumber { n = value.doubleValue }
        else if let value = value as? String { n = Double(value) }
        else { n = nil }
        guard let n, n.isFinite else { return nil }
        return n
    }
    private static func integer(_ value: Any?) -> Int? {
        guard let n = number(value), abs(n) <= 100000, n.rounded() == n else { return nil }
        return Int(n)
    }
    public static func decode(_ payload: Data, topic: String, now: Date = Date()) -> MQTTReading? {
        guard payload.count <= 65536,
              let obj = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              let timestamp = number(obj["ts"] ?? obj["timestamp"] ?? obj["gwts"]),
              timestamp > 0, timestamp <= now.timeIntervalSince1970 + 300,
              let rssi = integer(obj["rssi"]), (-127...20).contains(rssi) else { return nil }
        let date = Date(timeIntervalSince1970: timestamp)
        if let hex = obj["data"] as? String {
            guard hex.count % 2 == 0, hex.count <= 8192 else { return nil }
            let chars = Array(hex)
            var bytes: [UInt8] = []
            for i in stride(from: 0, to: chars.count, by: 2) {
                guard let byte = UInt8(String(chars[i...i+1]), radix: 16) else { return nil }
                bytes.append(byte)
            }
            var manufacturer: [UInt8]?
            if bytes.count == 26 && bytes.prefix(2) == [0x99, 0x04] { manufacturer = bytes }
            else {
                var i = 0
                while i < bytes.count {
                    let length = Int(bytes[i]); i += 1
                    if length == 0 { break }
                    guard i + length <= bytes.count else { return nil }
                    if bytes[i] == 255, length >= 3, Array(bytes[(i+1)...(i+2)]) == [0x99,0x04] {
                        manufacturer = Array(bytes[(i+1)..<(i+length)]); break
                    }
                    i += length
                }
            }
            guard let manufacturer, let decoded = AdvertisementDecoder.decode(Data(manufacturer), peripheralID: topic, rssi: rssi, date: date),
                  let identity = decoded.mac ?? mac(topic.split(separator: "/").last.map(String.init)) else { return nil }
            return MQTTReading(identity: identity, reading: decoded.reading, rssi: rssi)
        }
        guard integer(obj["data_format"]) == 5, let identity = mac(obj["mac"] as? String) else { return nil }
        let pressure = number(obj["pressure"]).map { $0 / 100 }
        let reading = Reading(date: date, temperature: number(obj["temperature"]), humidity: number(obj["humidity"]),
            pressure: pressure, voltage: number(obj["batteryVoltage"]), accelerationX: number(obj["accelerationX"]),
            accelerationY: number(obj["accelerationY"]), accelerationZ: number(obj["accelerationZ"]),
            movement: integer(obj["movementCounter"]), sequence: integer(obj["measurementSequenceNumber"]), txPower: integer(obj["txPower"]))
        return MQTTReading(identity: identity, reading: reading, rssi: rssi)
    }
}

public struct MQTTSettings {
    public var host: String
    public var port: Int
    public var topic: String
    public var username: String
    public var password: String
    public var tls: Bool
    public init(host: String, port: Int = 1883, topic: String = "ruuvi/#", username: String = "", password: String = "", tls: Bool = false) {
        self.host = host; self.port = port; self.topic = topic; self.username = username; self.password = password; self.tls = tls
    }
    public var validationError: String? {
        guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !host.contains("://"), (1...65535).contains(port) else { return "Enter a broker hostname and a port between 1 and 65535." }
        guard !topic.isEmpty, topic.utf8.count <= 65535, !topic.contains("\0") else { return "Enter a valid MQTT topic filter." }
        let parts = topic.split(separator: "/", omittingEmptySubsequences: false)
        for (i, part) in parts.enumerated() {
            if (part.contains("+") && part != "+") || (part.contains("#") && (part != "#" || i != parts.count - 1)) { return "Use + for one full topic level, or # as the last level." }
        }
        return nil
    }
}

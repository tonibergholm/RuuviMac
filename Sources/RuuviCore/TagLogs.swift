import Foundation

/// Official RuuviTag Nordic UART Service log-read framing (format 5 tags).
public final class TagLogAccumulator {
    public static let retention: TimeInterval = 10 * 86400
    public static let maxSamples = 14400
    public let now: UInt32
    public let start: UInt32
    public private(set) var complete = false
    private var values: [UInt32: Reading] = [:]
    public var count: Int { values.count }
    public init(now: Date, start: Date? = nil) {
        self.now = UInt32(max(0, min(now.timeIntervalSince1970, Double(UInt32.max-1))))
        self.start = UInt32(max(0, min((start ?? now.addingTimeInterval(-Self.retention)).timeIntervalSince1970, Double(self.now))))
    }
    public var request: Data {
        var result = Data([0x3A,0x3A,0x11])
        for number in [now,start] { result.append(contentsOf: [UInt8(number >> 24),UInt8(truncatingIfNeeded: number >> 16),UInt8(truncatingIfNeeded: number >> 8),UInt8(truncatingIfNeeded: number)]) }
        return result
    }
    public enum Failure: LocalizedError {
        case malformed, tagError, tooMany
        public var errorDescription: String? {
            switch self {
            case .malformed: return "Malformed tag history packet."
            case .tagError: return "Tag reported a log-transfer error. Retry the download."
            case .tooMany: return "Tag history exceeded the sample limit."
            }
        }
    }
    public func feed(_ data: Data) throws {
        let b = [UInt8](data)
        guard !complete, b.count >= 3, b[0] == 0x3A else { return }
        if b[2] == 0xF0 { throw Failure.tagError }
        guard b[2] == 0x10 else { return }
        guard b.count == 11 else { throw Failure.malformed }
        if b[3...10].allSatisfy({ $0 == 255 }) { complete = true; return }
        guard [0x30,0x31,0x32].contains(b[1]) else { return }
        func u32(_ offset: Int) -> UInt32 { b[offset..<offset+4].reduce(0) { ($0 << 8) | UInt32($1) } }
        let stamp = u32(3), raw = u32(7)
        guard stamp >= start, stamp <= now else { return }
        if b[1] == 0x30 && raw == 0x80000000 || b[1] != 0x30 && raw == UInt32.max { return }
        guard values[stamp] != nil || values.count < Self.maxSamples else { throw Failure.tooMany }
        var reading = values[stamp] ?? Reading(date: Date(timeIntervalSince1970: Double(stamp)))
        switch b[1] {
        case 0x30: reading.temperature = Double(Int32(bitPattern: raw)) / 100
        case 0x31: reading.humidity = Double(raw) / 100
        case 0x32: reading.pressure = Double(raw) / 100
        default: break
        }
        values[stamp] = reading
    }
    public var readings: [Reading] { values.keys.sorted().compactMap { values[$0] } }
}

public extension Sensor {
    /// Merge minute buckets without changing live readings, names, or freshness.
    @discardableResult mutating func mergeHistory(_ incoming: [Reading], now: Date) -> Int {
        var byMinute: [Int64: Reading] = [:]
        let cutoff = now.addingTimeInterval(-TagLogAccumulator.retention)
        for reading in history where reading.date > cutoff && reading.date <= now {
            byMinute[Int64(reading.date.timeIntervalSince1970 / 60)] = reading
        }
        var added = 0
        for reading in incoming where reading.date > cutoff && reading.date <= now {
            let key = Int64(reading.date.timeIntervalSince1970 / 60)
            if var existing = byMinute[key] {
                existing.temperature = existing.temperature ?? reading.temperature
                existing.humidity = existing.humidity ?? reading.humidity
                existing.pressure = existing.pressure ?? reading.pressure
                byMinute[key] = existing
            } else { byMinute[key] = reading; added += 1 }
        }
        history = Array(byMinute.values.sorted { $0.date < $1.date }.suffix(TagLogAccumulator.maxSamples))
        return added
    }
}

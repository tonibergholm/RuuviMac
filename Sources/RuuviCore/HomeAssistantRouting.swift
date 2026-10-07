import Foundation

public enum ReadingSource { case bluetooth, mqtt }

/// A deletion of a tag's retained discovery config, kept until the broker acknowledges it.
public struct PendingRemoval: Codable, Hashable {
    public let macKey: String
    public let host: String
    public let port: Int
    public let prefix: String
    public init(macKey: String, host: String, port: Int, prefix: String) {
        self.macKey = macKey; self.host = host; self.port = port; self.prefix = prefix
    }
    public var brokerKey: String { "\(host):\(port)/\(prefix)" }
}

/// Which tags this Mac publishes, where it published them, and removals not yet acknowledged.
public struct HomeAssistantLedger: Codable, Equatable {
    /// Per-tag choice for this Mac. Absent means not seen yet; the default setting applies.
    public private(set) var decisions: [String: Bool] = [:]
    public private(set) var published: [String: Set<String>] = [:]
    public private(set) var pending: [PendingRemoval] = []
    public init() {}

    public func isRemovalPending(_ macKey: String) -> Bool { pending.contains { $0.macKey == macKey } }
    public func isPublishing(_ macKey: String, publishNewTags: Bool) -> Bool {
        !isRemovalPending(macKey) && (decisions[macKey] ?? publishNewTags)
    }
    /// Records the default the first time a tag is seen. Returns true when a decision was added.
    @discardableResult public mutating func adopt(_ macKey: String, publishNewTags: Bool) -> Bool {
        guard decisions[macKey] == nil else { return false }
        decisions[macKey] = publishNewTags
        return true
    }
    public mutating func setPublishing(_ macKey: String, _ on: Bool) { decisions[macKey] = on }
    /// Returns true when this is the first publish of the tag to that broker.
    @discardableResult public mutating func markPublished(_ macKey: String, brokerKey: String) -> Bool {
        published[brokerKey, default: []].insert(macKey).inserted
    }
    @discardableResult public mutating func queueRemoval(_ macKey: String, settings: HomeAssistantSettings) -> PendingRemoval {
        decisions[macKey] = false
        let removal = PendingRemoval(macKey: macKey, host: settings.host, port: settings.port, prefix: settings.prefix)
        if !pending.contains(removal) { pending.append(removal) }
        return removal
    }
    /// Removes tags this Mac published to this broker and still owns.
    public mutating func queueRemoveAll(settings: HomeAssistantSettings) -> [PendingRemoval] {
        (published[settings.brokerKey] ?? []).filter { decisions[$0] == true }.sorted()
            .map { queueRemoval($0, settings: settings) }
    }
    public func pendingRemovals(for settings: HomeAssistantSettings) -> [PendingRemoval] {
        pending.filter { $0.host == settings.host && $0.port == settings.port && $0.prefix == settings.prefix }
    }
    public mutating func completeRemoval(_ removal: PendingRemoval) {
        pending.removeAll { $0 == removal }
        published[removal.brokerKey]?.remove(removal.macKey)
    }
}

/// At most one state publish per tag per interval.
public struct PublishThrottle {
    public let interval: TimeInterval
    private var last: [String: Date] = [:]
    public init(interval: TimeInterval = 60) { self.interval = interval }
    public mutating func shouldPublish(_ key: String, now: Date) -> Bool {
        if let previous = last[key], now.timeIntervalSince(previous) < interval { return false }
        last[key] = now
        return true
    }
    public mutating func resetAll() { last.removeAll() }
    public mutating func reset(_ key: String) { last[key] = nil }
}

/// Decides whether a reading goes to Home Assistant: Bluetooth only, MAC ids only, owned by this Mac, throttled.
public struct HomeAssistantRouter {
    public var throttle = PublishThrottle()
    public init() {}
    public mutating func route(id: String, source: ReadingSource, connected: Bool, ledger: inout HomeAssistantLedger,
                               publishNewTags: Bool, now: Date) -> String? {
        guard source == .bluetooth, let key = HomeAssistantDiscovery.macKey(id) else { return nil }
        ledger.adopt(key, publishNewTags: publishNewTags)
        guard connected, ledger.isPublishing(key, publishNewTags: publishNewTags),
              throttle.shouldPublish(key, now: now) else { return nil }
        return key
    }
}

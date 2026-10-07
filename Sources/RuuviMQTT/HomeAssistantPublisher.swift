import Foundation
import MQTTNIO
import NIOCore
import RuuviCore

/// Publishes discovery configs, state and availability to a Home Assistant broker.
/// All state is confined to the main queue; NIO callbacks hop back and check the client before use.
public final class HomeAssistantPublisher {
    public struct Tag: Equatable {
        public let macKey: String
        public var name: String
        public init(macKey: String, name: String) { self.macKey = macKey; self.name = name }
    }
    public let settings: HomeAssistantSettings
    private let password: String?
    private let bridge: String
    private let version: String
    public var onStatus: ((String) -> Void)?
    public var onConnected: (() -> Void)?
    public var onDisconnected: (() -> Void)?
    public var onBirth: (() -> Void)?
    public var onRemoved: ((PendingRemoval) -> Void)?
    public private(set) var connected = false
    private var client: MQTTClient?
    private var retry: DispatchWorkItem?
    private var stopped = true
    private var delay: Double = 1
    private var configured: Set<String> = []
    // Stable per bridge: a new publisher takes over the broker session, so a half-open old connection
    // cannot deliver its Last Will after the new "online".
    private let identifier: String
    private var closing: [MQTTClient] = []
    private var closedWaiters: [() -> Void] = []
    private var availability: String { HomeAssistantDiscovery.availabilityTopic(bridge: bridge) }

    public init(settings: HomeAssistantSettings, password: String?, bridge: String, version: String) {
        self.settings = settings; self.password = password; self.bridge = bridge; self.version = version
        self.identifier = "ruuvimac-ha-" + bridge
    }

    public func start() { stopped = false; connect() }

    private func connect() {
        guard !stopped, client == nil else { return }
        onStatus?("Connecting to the Home Assistant broker…")
        let configuration = MQTTClient.Configuration(keepAliveInterval: .seconds(30), connectTimeout: .seconds(10),
            timeout: .seconds(10),
            userName: settings.username.isEmpty ? nil : settings.username,
            password: settings.username.isEmpty ? nil : password,
            useSSL: settings.tls, tlsConfiguration: settings.tls ? .ts(TSTLSConfiguration()) : nil)
        let c = MQTTClient(host: settings.host, port: settings.port, identifier: identifier,
                           eventLoopGroupProvider: .createNew, configuration: configuration)
        client = c
        let availability = self.availability
        let birthTopic = HomeAssistantDiscovery.birthTopic(prefix: settings.prefix)
        c.addPublishListener(named: "birth") { [weak self, weak c] result in
            guard case .success(let message) = result, message.topicName == birthTopic else { return }
            var buffer = message.payload
            let text = buffer.readString(length: buffer.readableBytes)
            DispatchQueue.main.async {
                guard let self, let c, self.client === c, self.connected, text == "online" else { return }
                self.onBirth?()
            }
        }
        c.addCloseListener(named: "reconnect") { [weak self, weak c] _ in
            DispatchQueue.main.async { self?.failed(c, message: "Home Assistant broker disconnected; reconnecting…") }
        }
        // MQTTNIO 2.13.0 sends the will at QoS 0; the retain flag is kept.
        let will = (topicName: availability, payload: ByteBuffer(string: "offline"), qos: MQTTQoS.atLeastOnce, retain: true)
        c.connect(will: will)
            .flatMap { _ in c.publish(to: availability, payload: ByteBuffer(string: "online"), qos: .atLeastOnce, retain: true) }
            .flatMap { c.subscribe(to: [.init(topicFilter: birthTopic, qos: .atLeastOnce)]) }
            .whenComplete { [weak self, weak c] result in
                DispatchQueue.main.async {
                    guard let self, let c, self.client === c, !self.stopped else { return }
                    switch result {
                    case .success(let suback):
                        if suback.returnCodes.contains(where: { if case .failure = $0 { return true }; return false }) {
                            self.failed(c, message: "The broker rejected the Home Assistant status subscription. Retrying…")
                            return
                        }
                        self.delay = 1; self.connected = true; self.configured = []
                        self.onStatus?("Connected to the Home Assistant broker")
                        self.onConnected?()
                    case .failure(let error):
                        self.failed(c, message: Self.describe(error))
                    }
                }
            }
    }

    static func describe(_ error: Error) -> String {
        if case MQTTError.connectionError(let code) = error {
            switch code {
            case .badUserNameOrPassword, .notAuthorized: return "The broker rejected the username or password. Retrying…"
            default: return "The broker refused the connection (\(code)). Retrying…"
            }
        }
        return "Could not reach the Home Assistant broker; check host, port and TLS. Retrying…"
    }

    /// Drops the current client and schedules a reconnect with backoff.
    private func failed(_ c: MQTTClient?, message: String) {
        guard let c, client === c, !stopped else { return }
        client = nil
        if connected { connected = false; onDisconnected?() }
        configured = []
        onStatus?(message)
        let wait = delay
        delay = min(delay * 2, 30)
        c.removeCloseListener(named: "reconnect")
        // Reconnect only after the old socket has closed, so its Last Will cannot land after the new "online".
        closing.append(c)
        c.shutdown { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.closing.removeAll { $0 === c }
                if self.closing.isEmpty {
                    let waiters = self.closedWaiters; self.closedWaiters = []
                    waiters.forEach { MainRunLoop.perform($0) }
                }
                guard !self.stopped else { return }
                let task = DispatchWorkItem { [weak self] in self?.connect() }
                self.retry = task
                DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: task)
            }
        }
    }

    /// Reports a failed publish on `c` as a broken connection, if `c` is still the current client.
    private func publishFailed(_ c: MQTTClient) {
        DispatchQueue.main.async { [weak self] in
            self?.failed(c, message: "Publishing to the Home Assistant broker failed; reconnecting…")
        }
    }

    public func publishConfig(tag: Tag) {
        guard connected, let c = client else { return }
        let payload = HomeAssistantDiscovery.config(macKey: tag.macKey, name: tag.name, bridge: bridge, version: version)
        configured.insert(tag.macKey)
        c.publish(to: HomeAssistantDiscovery.configTopic(prefix: settings.prefix, macKey: tag.macKey),
                  payload: ByteBuffer(bytes: payload), qos: .atLeastOnce, retain: true)
            .whenFailure { [weak self] _ in self?.publishFailed(c) }
    }

    /// Sends the tag's config first if this connection has not sent it yet, then the state.
    public func publish(tag: Tag, reading: Reading, rssi: Int) {
        guard connected, let c = client else { return }
        if !configured.contains(tag.macKey) { publishConfig(tag: tag) }
        c.publish(to: HomeAssistantDiscovery.stateTopic(macKey: tag.macKey),
                  payload: ByteBuffer(bytes: HomeAssistantDiscovery.state(reading, rssi: rssi)), qos: .atMostOnce)
            .whenFailure { [weak self] _ in self?.publishFailed(c) }
    }

    /// Empty retained config at QoS 1. `onRemoved` fires only after the broker acknowledges it.
    public func remove(_ removal: PendingRemoval) {
        guard connected, let c = client, removal.brokerKey == settings.brokerKey else { return }
        configured.remove(removal.macKey)
        c.publish(to: HomeAssistantDiscovery.configTopic(prefix: removal.prefix, macKey: removal.macKey),
                  payload: ByteBuffer(), qos: .atLeastOnce, retain: true)
            .whenComplete { [weak self] result in
                switch result {
                case .success: DispatchQueue.main.async { self?.onRemoved?(removal) }
                case .failure: self?.publishFailed(c)
                }
            }
    }

    /// Ordered shutdown: stop retries, publish retained offline and wait for the ack, disconnect, shut down.
    /// `closed` runs exactly once on the main run loop, never synchronously, after every client this publisher
    /// opened has closed, or after `timeout` when the deadline forces it.
    /// If the broker has not acknowledged within `timeout` seconds the socket is closed anyway and the broker's
    /// Last Will marks this bridge offline. Callers that need a hard time bound (quit) add their own deadline.
    public func stop(timeout: TimeInterval = 2, closed: @escaping () -> Void) {
        stopped = true; retry?.cancel(); retry = nil
        let wasConnected = connected
        if connected { connected = false; onDisconnected?() }
        configured = []
        var completed = false
        var deadline: Timer?
        let complete = {
            guard !completed else { return }
            completed = true; deadline?.invalidate(); closed()
        }
        guard let c = client else {
            if closing.isEmpty { MainRunLoop.perform(complete); return }
            closedWaiters.append(complete)
            deadline = MainRunLoop.after(timeout) { complete() }
            return
        }
        client = nil
        c.removeCloseListener(named: "reconnect")
        // shutdown is idempotent; a second call reports alreadyShutdown, which is ignored.
        let finish = { c.shutdown { error in
            if let mqtt = error as? MQTTError, case .alreadyShutdown = mqtt { return }
            MainRunLoop.perform(complete)
        } }
        deadline = MainRunLoop.after(timeout) { finish() }
        guard wasConnected, c.isActive() else { finish(); return }
        c.publish(to: availability, payload: ByteBuffer(string: "offline"), qos: .atLeastOnce, retain: true)
            .flatMap { c.disconnect() }
            .whenComplete { _ in finish() }
    }

    /// Runs the normal failure path: the socket closes without DISCONNECT, so the broker sends the Last Will,
    /// and the reconnect is scheduled after the close completes.
    func dropConnectionForTesting() {
        failed(client, message: "Connection dropped for testing; reconnecting…")
    }
}

import Foundation
import MQTTNIO
import RuuviCore

/// All state is confined to the main queue; NIO callbacks hop back before use.
public final class MQTTInput {
    let settings: MQTTSettings
    public var onReading: ((MQTTReading) -> Void)?
    public var onStatus: ((String) -> Void)?
    private var client: MQTTClient?
    private var retry: DispatchWorkItem?
    private var stopped = true
    private var delay: Double = 1
    private let identifier = "ruuvimac-" + UUID().uuidString
    public init(settings: MQTTSettings) { self.settings = settings }
    public func start() { stopped = false; connect() }
    private func connect() {
        guard !stopped else { return }
        onStatus?("Connecting to MQTT…")
        let configuration = MQTTClient.Configuration(keepAliveInterval: .seconds(30), connectTimeout: .seconds(10),
            userName: settings.username.isEmpty ? nil : settings.username,
            password: settings.username.isEmpty ? nil : settings.password,
            useSSL: settings.tls, tlsConfiguration: settings.tls ? .ts(TSTLSConfiguration()) : nil)
        let c = MQTTClient(host: settings.host, port: settings.port, identifier: identifier,
            eventLoopGroupProvider: .createNew, configuration: configuration)
        client = c
        c.addPublishListener(named: "readings") { [weak self, weak c] result in
            guard case .success(let message) = result else { return }
            var buffer = message.payload
            guard let bytes = buffer.readBytes(length: buffer.readableBytes) else { return }
            let decoded = MQTTMessageDecoder.decode(Data(bytes), topic: message.topicName)
            DispatchQueue.main.async {
                guard let self, self.client === c, !self.stopped else { return }
                if let decoded { self.onReading?(decoded) }
            }
        }
        c.addCloseListener(named: "reconnect") { [weak self, weak c] _ in
            DispatchQueue.main.async { self?.failed(c, message: "MQTT disconnected; reconnecting…") }
        }
        c.connect().flatMap { _ in c.subscribe(to: [.init(topicFilter: self.settings.topic, qos: .atLeastOnce)]) }.whenComplete { [weak self, weak c] result in
            DispatchQueue.main.async {
                guard let self, self.client === c, !self.stopped else { return }
                switch result {
                case .success(let ack):
                    if ack.returnCodes.contains(where: { if case .failure = $0 { return true }; return false }) {
                        self.failed(c, message: "MQTT subscription rejected by broker.")
                    } else { self.delay = 1; self.onStatus?("MQTT subscribed · " + self.settings.topic) }
                case .failure:
                    self.failed(c, message: "MQTT connection failed; check broker, credentials, and TLS. Retrying…")
                }
            }
        }
    }
    private func failed(_ c: MQTTClient?, message: String) {
        guard let c, client === c, !stopped else { return }
        client = nil; c.removeCloseListener(named: "reconnect"); c.shutdown { _ in }
        onStatus?(message)
        let task = DispatchWorkItem { [weak self] in self?.connect() }
        retry = task; DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
        delay = min(delay * 2, 30)
    }
    public func stop() {
        stopped = true; retry?.cancel(); retry = nil
        let c = client; client = nil
        c?.removeCloseListener(named: "reconnect"); c?.shutdown { _ in }
    }
}

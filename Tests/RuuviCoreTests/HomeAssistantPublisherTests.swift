import XCTest
import MQTTNIO
import NIOPosix
@testable import RuuviCore
@testable import RuuviMQTT

final class HomeAssistantPublisherTests: XCTestCase {
    /// Records every message an observer client receives, thread-safely.
    final class Inbox {
        private let lock = NSLock()
        private var items: [(topic: String, payload: String)] = []
        func add(_ topic: String, _ payload: String) { lock.lock(); items.append((topic, payload)); lock.unlock() }
        func all() -> [(topic: String, payload: String)] { lock.lock(); defer { lock.unlock() }; return items }
        func clear() { lock.lock(); items.removeAll(); lock.unlock() }
        func waitFor(_ timeout: TimeInterval = 5, _ predicate: ([(topic: String, payload: String)]) -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if predicate(all()) { return true }
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            return predicate(all())
        }
    }

    func observer(port: Int, filters: [String], inbox: Inbox) throws -> MQTTClient {
        let client = MQTTClient(host: "127.0.0.1", port: port, identifier: UUID().uuidString, eventLoopGroupProvider: .shared(MultiThreadedEventLoopGroup.singleton))
        client.addPublishListener(named: "inbox") { result in
            guard case .success(let m) = result else { return }
            var b = m.payload
            inbox.add(m.topicName, b.readString(length: b.readableBytes) ?? "")
        }
        _ = try client.connect().wait()
        _ = try client.subscribe(to: filters.map { .init(topicFilter: $0, qos: .atLeastOnce) }).wait()
        return client
    }

    func testDiscoveryAvailabilityBirthWillRemovalAndShutdown() throws {
        XCTAssertTrue(Thread.isMainThread, "callbacks and counters below rely on the main run loop")
        guard let portText = ProcessInfo.processInfo.environment["RUUVI_MQTT_TEST_PORT"], let port = Int(portText) else { throw XCTSkip("No test broker supplied") }
        let run = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let prefix = "ruuvimac-test-\(run.prefix(8))"
        let bridge = String(run.prefix(8)), key = String(run.suffix(12))
        let settings = HomeAssistantSettings(host: "127.0.0.1", port: port, prefix: prefix)
        let availability = HomeAssistantDiscovery.availabilityTopic(bridge: bridge)
        let config = HomeAssistantDiscovery.configTopic(prefix: prefix, macKey: key)
        let state = HomeAssistantDiscovery.stateTopic(macKey: key)
        let inbox = Inbox()
        let watcher = try observer(port: port, filters: ["\(prefix)/#", availability, state], inbox: inbox)
        defer { try? watcher.syncShutdownGracefully() }

        let publisher = HomeAssistantPublisher(settings: settings, password: nil, bridge: bridge, version: "test")
        var connects = 0, births = 0, disconnects = 0
        var removedKeys: [String] = []
        publisher.onConnected = { connects += 1 }
        publisher.onDisconnected = { disconnects += 1 }
        publisher.onBirth = { births += 1 }
        publisher.onRemoved = { removedKeys.append($0.macKey) }
        publisher.start()
        XCTAssertTrue(inbox.waitFor(10) { _ in connects == 1 })
        XCTAssertTrue(inbox.waitFor { $0.contains { $0 == (availability, "online") } })

        // Config is sent before the first state.
        publisher.publish(tag: .init(macKey: key, name: "Sauna"), reading: Reading(date: Date(), temperature: 21), rssi: -60)
        XCTAssertTrue(inbox.waitFor { items in items.contains { $0.topic == state } })
        let topics = inbox.all().map(\.topic)
        XCTAssertLessThan(try XCTUnwrap(topics.firstIndex(of: config)), try XCTUnwrap(topics.firstIndex(of: state)))

        // The config is retained: a later subscriber receives it.
        let lateInbox = Inbox()
        let late = try observer(port: port, filters: [config], inbox: lateInbox)
        XCTAssertTrue(lateInbox.waitFor { $0.contains { $0.topic == config && !$0.payload.isEmpty } })
        try late.syncShutdownGracefully()

        // Home Assistant birth message.
        _ = try watcher.publish(to: HomeAssistantDiscovery.birthTopic(prefix: prefix), payload: .init(string: "online"), qos: .atLeastOnce).wait()
        XCTAssertTrue(inbox.waitFor { _ in births == 1 })

        // Abrupt drop: broker publishes the Last Will, publisher reconnects and republishes online.
        inbox.clear()
        publisher.dropConnectionForTesting()
        XCTAssertTrue(inbox.waitFor(10) { $0.contains { $0 == (availability, "offline") } }, "Last Will not delivered")
        XCTAssertEqual(disconnects, 1)
        XCTAssertTrue(inbox.waitFor(15) { _ in connects == 2 })
        XCTAssertTrue(inbox.waitFor { $0.contains { $0 == (availability, "online") } })

        // Removal: empty retained config, acknowledged.
        publisher.remove(PendingRemoval(macKey: key, host: "127.0.0.1", port: port, prefix: prefix))
        XCTAssertTrue(inbox.waitFor { _ in removedKeys == [key] })
        XCTAssertTrue(inbox.waitFor { $0.contains { $0 == (config, "") } })

        // Ordered shutdown publishes offline and completes once.
        inbox.clear()
        var completions = 0
        publisher.stop { completions += 1 }
        XCTAssertTrue(inbox.waitFor { _ in completions == 1 })
        XCTAssertTrue(inbox.waitFor { $0.contains { $0 == (availability, "offline") } }, "ordered shutdown did not publish offline")
        RunLoop.main.run(until: Date().addingTimeInterval(2.5))
        XCTAssertEqual(completions, 1, "stop must complete exactly once")
        _ = try watcher.publish(to: availability, payload: .init(), qos: .atLeastOnce, retain: true).wait()
    }

    func testStopWithoutConnectionCompletesAsynchronously() {
        let publisher = HomeAssistantPublisher(settings: HomeAssistantSettings(host: "127.0.0.1", port: 1), password: nil, bridge: "00000000", version: "test")
        XCTAssertTrue(Thread.isMainThread)
        var done = false
        publisher.stop { done = true }
        XCTAssertFalse(done, "completion must not run synchronously")
        let deadline = Date().addingTimeInterval(1)
        while !done && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertTrue(done)
    }

    func testStopWhileConnectingToUnreachableBrokerCompletesOnce() {
        XCTAssertTrue(Thread.isMainThread)
        let publisher = HomeAssistantPublisher(settings: HomeAssistantSettings(host: "127.0.0.1", port: 9), password: nil, bridge: "00000001", version: "test")
        publisher.start()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        var count = 0
        publisher.stop { count += 1 }
        XCTAssertEqual(count, 0, "completion must not run synchronously")
        let deadline = Date().addingTimeInterval(3)
        while count < 1 && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertEqual(count, 1)
        RunLoop.main.run(until: Date().addingTimeInterval(2.5))
        XCTAssertEqual(count, 1, "stop must complete exactly once")
    }
}

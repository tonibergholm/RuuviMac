import XCTest
@testable import RuuviCore

final class HomeAssistantRoutingTests: XCTestCase {
    let mac = "C4:A1:B2:D3:E4:F5", key = "c4a1b2d3e4f5"
    let t0 = Date(timeIntervalSince1970: 1_000)
    let settings = HomeAssistantSettings(host: "ha.local")

    func testThrottle() {
        var throttle = PublishThrottle()
        XCTAssertTrue(throttle.shouldPublish(key, now: t0))
        XCTAssertTrue(throttle.shouldPublish("other", now: t0))
        XCTAssertFalse(throttle.shouldPublish(key, now: t0.addingTimeInterval(59)))
        XCTAssertTrue(throttle.shouldPublish(key, now: t0.addingTimeInterval(60)))
        throttle.reset(key)
        XCTAssertTrue(throttle.shouldPublish(key, now: t0.addingTimeInterval(61)))
        XCTAssertFalse(throttle.shouldPublish("other", now: t0.addingTimeInterval(30)), "reset of one tag must not reset others")
        throttle.resetAll()
        XCTAssertTrue(throttle.shouldPublish(key, now: t0.addingTimeInterval(62)))
        XCTAssertTrue(throttle.shouldPublish("other", now: t0.addingTimeInterval(62)))
    }

    func testThrottleAllowsAfterClockMovesBackward() {
        var throttle = PublishThrottle()
        XCTAssertTrue(throttle.shouldPublish(key, now: t0.addingTimeInterval(100)))
        XCTAssertTrue(throttle.shouldPublish(key, now: t0))
        XCTAssertFalse(throttle.shouldPublish(key, now: t0.addingTimeInterval(10)))
    }

    func testRouterFiltersSourceIdentityConnectionAndOwnership() {
        var router = HomeAssistantRouter()
        var ledger = HomeAssistantLedger()
        XCTAssertNil(router.route(id: mac, source: .mqtt, connected: true, ledger: &ledger, publishNewTags: true, now: t0))
        XCTAssertNil(ledger.decisions[key], "MQTT readings must not adopt tags")
        XCTAssertNil(router.route(id: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F", source: .bluetooth, connected: true, ledger: &ledger, publishNewTags: true, now: t0))
        XCTAssertNil(router.route(id: mac, source: .bluetooth, connected: false, ledger: &ledger, publishNewTags: true, now: t0))
        XCTAssertEqual(ledger.decisions[key], true, "first Bluetooth sighting records the default")
        // A disconnected attempt must not consume the throttle.
        XCTAssertEqual(router.route(id: mac, source: .bluetooth, connected: true, ledger: &ledger, publishNewTags: true, now: t0), key)
        XCTAssertNil(router.route(id: mac, source: .bluetooth, connected: true, ledger: &ledger, publishNewTags: true, now: t0.addingTimeInterval(10)))
        ledger.setPublishing(key, false)
        router.throttle.resetAll()
        XCTAssertNil(router.route(id: mac, source: .bluetooth, connected: true, ledger: &ledger, publishNewTags: true, now: t0.addingTimeInterval(100)))
    }

    func testPendingRemovalBlocksRouting() {
        var router = HomeAssistantRouter()
        var ledger = HomeAssistantLedger()
        ledger.queueRemoval(key, settings: settings)
        ledger.setPublishing(key, true)
        XCTAssertNil(router.route(id: mac, source: .bluetooth, connected: true, ledger: &ledger, publishNewTags: true, now: t0))
    }

    func testDecisionIsRecordedOnceAndNotRetroactive() {
        var ledger = HomeAssistantLedger()
        XCTAssertTrue(ledger.adopt(key, publishNewTags: false))
        XCTAssertFalse(ledger.adopt(key, publishNewTags: true))
        XCTAssertFalse(ledger.isPublishing(key, publishNewTags: true), "turning the default on must not flip a recorded tag")
        ledger.setPublishing(key, true)
        XCTAssertTrue(ledger.isPublishing(key, publishNewTags: false))
        XCTAssertTrue(ledger.isPublishing("aaaaaaaaaaaa", publishNewTags: true), "unseen tags follow the default")
        XCTAssertFalse(ledger.isPublishing("aaaaaaaaaaaa", publishNewTags: false))
    }

    func testRemovalLifecycle() throws {
        var ledger = HomeAssistantLedger()
        ledger.adopt(key, publishNewTags: true)
        XCTAssertTrue(ledger.markPublished(key, brokerKey: settings.brokerKey))
        XCTAssertFalse(ledger.markPublished(key, brokerKey: settings.brokerKey))
        let removal = ledger.queueRemoval(key, settings: settings)
        XCTAssertEqual(removal, PendingRemoval(macKey: key, host: "ha.local", port: 1883, prefix: "homeassistant"))
        XCTAssertTrue(ledger.isRemovalPending(key))
        XCTAssertFalse(ledger.isPublishing(key, publishNewTags: true))
        XCTAssertEqual(ledger.queueRemoval(key, settings: settings), removal)
        XCTAssertEqual(ledger.pendingRemovals(for: settings), [removal])
        XCTAssertEqual(ledger.pendingRemovals(for: HomeAssistantSettings(host: "other.local")), [])
        XCTAssertEqual(ledger.pendingRemovals(for: HomeAssistantSettings(host: "ha.local", prefix: "ha")), [])
        let restored = try JSONDecoder().decode(HomeAssistantLedger.self, from: JSONEncoder().encode(ledger))
        XCTAssertEqual(restored.pendingRemovals(for: settings), [removal])
        ledger.completeRemoval(removal)
        XCTAssertFalse(ledger.isRemovalPending(key))
        XCTAssertEqual(ledger.pendingRemovals(for: settings), [])
        XCTAssertNil(ledger.published[settings.brokerKey]?.first)
        XCTAssertFalse(ledger.isPublishing(key, publishNewTags: true))
    }

    func testRemoveAllCoversOnlyOwnedTagsOnThisBroker() {
        var ledger = HomeAssistantLedger()
        for k in ["aaaaaaaaaaaa", "bbbbbbbbbbbb", "dddddddddddd"] {
            ledger.adopt(k, publishNewTags: true); ledger.markPublished(k, brokerKey: settings.brokerKey)
        }
        ledger.setPublishing("dddddddddddd", false)   // handed to another Mac
        ledger.adopt("cccccccccccc", publishNewTags: true)
        ledger.markPublished("cccccccccccc", brokerKey: HomeAssistantSettings(host: "other.local").brokerKey)
        let queued = ledger.queueRemoveAll(settings: settings)
        XCTAssertEqual(queued.map(\.macKey), ["aaaaaaaaaaaa", "bbbbbbbbbbbb"])
        XCTAssertTrue(ledger.isPublishing("cccccccccccc", publishNewTags: true))
        XCTAssertFalse(ledger.isRemovalPending("dddddddddddd"))
    }
}

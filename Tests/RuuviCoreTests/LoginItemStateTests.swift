import XCTest
@testable import RuuviCore

final class LoginItemStateTests: XCTestCase {
    func testAwaitingApprovalCountsAsRegistered() {
        var state = LoginItemState()
        state.observe(registered: true, needsApproval: true)
        XCTAssertTrue(state.registered)
        XCTAssertTrue(state.needsApproval)
    }

    func testFailedUnregisterKeepsMessageWhenStatusUnchanged() {
        var state = LoginItemState()
        state.observe(registered: true, needsApproval: false)
        state.failed("x")
        state.observe(registered: true, needsApproval: false)
        XCTAssertEqual(state.message, "x")
    }

    func testRealTransitionClearsMessage() {
        var state = LoginItemState()
        state.observe(registered: false, needsApproval: false)
        state.failed("x")
        state.observe(registered: true, needsApproval: true)
        XCTAssertNil(state.message)
    }

    func testSuccessClearsMessage() {
        var state = LoginItemState()
        state.failed("x")
        state.succeeded()
        XCTAssertNil(state.message)
    }

    func testUnchangedRefreshKeepsMessageAcrossRepeats() {
        var state = LoginItemState()
        state.observe(registered: false, needsApproval: false)
        state.failed("x")
        for _ in 0..<3 { state.observe(registered: false, needsApproval: false) }
        XCTAssertEqual(state.message, "x")
    }
}

import XCTest
@testable import RuuviCore

final class KeychainErrorTests: XCTestCase {
    func testMessagesIncludeStatusCodes() {
        XCTAssertTrue(KeychainError.notFound.message.contains("-25300"))
        XCTAssertTrue(KeychainError.status(-25293).message.contains("-25293"))
        XCTAssertTrue(KeychainError.status(-128).message.contains("-128"))
    }
}

final class KeychainPasswordStoreTests: XCTestCase {
    var store: KeychainPasswordStore!
    let account = "ruuvi@ha.local:1883"
    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["RUUVI_KEYCHAIN_TESTS"] == "1" else { throw XCTSkip("Set RUUVI_KEYCHAIN_TESTS=1 to use the login Keychain") }
        store = KeychainPasswordStore(service: "org.ruuvimac.tests.\(UUID().uuidString)")
    }
    override func tearDownWithError() throws { try? store?.delete(account: account) }

    func testMissingItemIsNotFound() {
        XCTAssertThrowsError(try store.read(account: account)) { XCTAssertEqual($0 as? KeychainError, .notFound) }
    }
    func testSaveReadUpdateDelete() throws {
        try store.save("first", account: account)
        XCTAssertEqual(try store.read(account: account), "first")
        try store.save("second", account: account)
        XCTAssertEqual(try store.read(account: account), "second")
        try store.delete(account: account)
        XCTAssertThrowsError(try store.read(account: account))
        XCTAssertNoThrow(try store.delete(account: account))
    }
}

@testable import LemurCam
import XCTest

/// Tests `KeychainService` against the real Keychain, under a service of its own so
/// the app's saved camera logins are never read, changed or deleted. Each test uses
/// a fresh account and `tearDown` deletes it.
internal final class KeychainTests: XCTestCase {
    private let keychain = KeychainService(service: "cam.lemur.app.tests.credentials")
    private var testID: UUID?

    override func setUp() {
        super.setUp()
        testID = UUID()
    }

    override func tearDown() {
        if let testID { try? keychain.delete(for: testID) }
        super.tearDown()
    }

    func testSaveAndRetrieve() throws {
        guard let testID else { XCTFail("testID not initialized"); return }
        let creds = SourceCredentials(username: "admin", password: "secret123")
        try keychain.save(credentials: creds, for: testID)

        let retrieved = try keychain.retrieve(for: testID)
        XCTAssertEqual(retrieved, creds)
    }

    func testRetrieveNonExistent() throws {
        let retrieved = try keychain.retrieve(for: UUID())
        XCTAssertNil(retrieved)
    }

    func testUpdate() throws {
        guard let testID else { XCTFail("testID not initialized"); return }
        let original = SourceCredentials(username: "admin", password: "old")
        try keychain.save(credentials: original, for: testID)

        let updated = SourceCredentials(username: "admin", password: "new")
        try keychain.save(credentials: updated, for: testID)

        let retrieved = try keychain.retrieve(for: testID)
        XCTAssertEqual(retrieved, updated)
    }

    func testDelete() throws {
        guard let testID else { XCTFail("testID not initialized"); return }
        let creds = SourceCredentials(username: "user", password: "pass")
        try keychain.save(credentials: creds, for: testID)
        try keychain.delete(for: testID)

        let retrieved = try keychain.retrieve(for: testID)
        XCTAssertNil(retrieved)
    }

    func testDeleteNonExistentDoesNotThrow() throws {
        XCTAssertNoThrow(try keychain.delete(for: UUID()))
    }
}

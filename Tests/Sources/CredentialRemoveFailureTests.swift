@testable import LemurCam
import XCTest

/// An edit that turns a camera's login off removes it from the Keychain after the
/// cameras file is written. A failed removal was only logged: an RTSP camera edited
/// from `rtsp://192.168.1.10/s` to `rtsp://192.168.1.20/s` with Requires
/// Authentication off was saved, the form closed, and the old login went to
/// 192.168.1.20. The edit is now undone and the form told, as when new credentials
/// can't be stored. The storage's writes are stubbed where they fail; credentials go
/// to an in-memory store.
@MainActor
internal final class CredentialRemoveFailureTests: XCTestCase {
    /// Lets a number of file writes work, then fails every one after.
    private final class WriteCountdown {
        var writesLeft = Int.max

        func nextWriteFails() -> Bool {
            guard writesLeft > 0 else { return true }
            writesLeft -= 1
            return false
        }
    }

    private struct WriteFailure: Error {}

    private static let login = SourceCredentials(username: "admin", password: "pw")
    private static let saved = SourceType.rtsp(RTSPSourceInfo(url: "rtsp://192.168.1.10/s"))
    private static let edited = SourceType.rtsp(RTSPSourceInfo(url: "rtsp://192.168.1.20/s"))

    private var directory: URL?
    private var savedActiveID: String?

    override func setUp() async throws {
        try await super.setUp()
        // Changes save the active camera in the host app's standard defaults.
        savedActiveID = UserDefaults.standard.string(forKey: LemurCamConfig.activeSourceKey)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() async throws {
        if let savedActiveID {
            UserDefaults.standard.set(savedActiveID, forKey: LemurCamConfig.activeSourceKey)
        } else {
            UserDefaults.standard.removeObject(forKey: LemurCamConfig.activeSourceKey)
        }
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try await super.tearDown()
    }

    private struct Fixture {
        let manager: SourceManager
        let keychain: InMemoryCredentialStore
        let writes: WriteCountdown
        let fileURL: URL
        let id: UUID
    }

    /// "Porch" saved at `saved` with `login`; then the Keychain can't delete.
    private func makeFixture() throws -> Fixture {
        let fileURL = try XCTUnwrap(directory).appendingPathComponent("sources.json")
        let writes = WriteCountdown()
        let storage = SourceStorage(fileURL: fileURL) { data, url in
            if writes.nextWriteFails() { throw WriteFailure() }
            try data.write(to: url, options: .atomic)
        }
        let keychain = InMemoryCredentialStore()
        let manager = SourceManager(storage: storage, keychain: keychain)
        try manager.addSource(name: "Porch", sourceType: Self.saved, credentials: Self.login)
        keychain.failDeletes = true
        return Fixture(
            manager: manager, keychain: keychain, writes: writes, fileURL: fileURL,
            id: try XCTUnwrap(manager.sources.first?.id)
        )
    }

    private func savedSources(in url: URL) throws -> [CameraSource] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([CameraSource].self, from: Data(contentsOf: url))
    }

    /// What the edit form saves with Requires Authentication off.
    private func turnLoginOff(_ fixture: Fixture, to type: SourceType, name: String = "Porch") -> (any Error)? {
        let change = CredentialChange.fromForm(
            authenticationEnabled: false, username: "", password: "", storedCredentialsUnreadable: false
        )
        do {
            try fixture.manager.updateSource(id: fixture.id, name: name, sourceType: type, credentials: change)
        } catch {
            return error
        }
        return nil
    }

    func testAnEditWhoseLoginCantBeRemovedIsUndone() throws {
        let fixture = try makeFixture()
        var configChanges = 0
        fixture.manager.onSourceConfigChanged = { configChanges += 1 }

        let error = turnLoginOff(fixture, to: Self.edited)

        XCTAssertTrue(error is CredentialRemoveError, String(describing: error))
        XCTAssertEqual(fixture.manager.sources.first?.sourceType, Self.saved)
        XCTAssertEqual(try savedSources(in: fixture.fileURL).map(\.sourceType), [Self.saved])
        XCTAssertEqual(fixture.keychain.stored[fixture.id], Self.login, "the login stays with the address it was for")
        XCTAssertFalse(fixture.manager.lastSaveFailed)
        XCTAssertEqual(configChanges, 0, "the camera is as it was")
    }

    /// Whatever else the edit changed: the user turned the login off, and it stayed.
    func testARenameWhoseLoginCantBeRemovedIsUndoneToo() throws {
        let fixture = try makeFixture()

        let error = turnLoginOff(fixture, to: Self.saved, name: "Garage")

        XCTAssertTrue(error is CredentialRemoveError, String(describing: error))
        XCTAssertEqual(fixture.manager.sources.first?.name, "Porch")
        XCTAssertEqual(fixture.keychain.stored[fixture.id], Self.login)
    }

    func testALoginTheKeychainRemovesIsSavedOff() throws {
        let fixture = try makeFixture()
        fixture.keychain.failDeletes = false

        XCTAssertNil(turnLoginOff(fixture, to: Self.edited))

        XCTAssertEqual(fixture.manager.sources.first?.sourceType, Self.edited)
        XCTAssertNil(fixture.keychain.stored[fixture.id])
    }

    /// The file can't be put back either: the camera stays as edited, with its old
    /// login, and the error says so.
    func testAnEditThatCantBeUndoneSaysTheOldLoginStayed() throws {
        let fixture = try makeFixture()
        fixture.writes.writesLeft = 1
        var configChanges = 0
        fixture.manager.onSourceConfigChanged = { configChanges += 1 }

        let error = turnLoginOff(fixture, to: Self.edited)

        XCTAssertTrue(error is EditSavedWithOldLoginError, String(describing: error))
        XCTAssertEqual(fixture.manager.sources.first?.sourceType, Self.edited)
        XCTAssertEqual(try savedSources(in: fixture.fileURL).map(\.sourceType), [Self.edited])
        XCTAssertEqual(fixture.keychain.stored[fixture.id], Self.login)
        XCTAssertFalse(fixture.manager.lastSaveFailed, "the app holds what the file holds")
        XCTAssertEqual(configChanges, 1, "the stream reconnects to the camera as saved")
    }

    /// The first is shown in the edit form, which stays open with what was entered;
    /// the second in the camera list, once the form closed on the saved edit.
    func testTheErrorsSayWhatHappened() {
        let undone = CredentialRemoveError().localizedDescription
        XCTAssertTrue(undone.contains("couldn't be removed"), undone)
        XCTAssertTrue(undone.contains("wasn't saved"), undone)
        let kept = EditSavedWithOldLoginError().localizedDescription
        XCTAssertTrue(kept.contains("was saved"), kept)
        XCTAssertTrue(kept.contains("couldn't be removed"), kept)
    }
}

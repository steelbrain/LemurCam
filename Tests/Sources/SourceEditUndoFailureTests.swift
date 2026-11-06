@testable import LemurCam
import XCTest

/// An edit is written to `sources.json` before its new credentials go to the Keychain,
/// and credentials that can't be stored put the file back. When that write failed too,
/// the file kept the edited camera, with its new address, while the Keychain kept the
/// old login, and the form said the change wasn't made: after a restart the old
/// password went to the new address. The camera now stays as edited, in the app and in
/// the file, without a login, and the error says so. The storage's writes are stubbed;
/// credentials go to an in-memory store.
@MainActor
internal final class SourceEditUndoFailureTests: XCTestCase {
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

    private static let oldLogin = SourceCredentials(username: "admin", password: "old-pw")
    private static let newLogin = SourceCredentials(username: "admin", password: "new-pw")
    private static let edited = SourceType.rtsp(RTSPSourceInfo(url: "rtsp://192.0.2.9/s"))

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
        let fileURL: URL
        let id: UUID
    }

    /// "Porch" saved at rtsp://192.0.2.1/s with `oldLogin`. Then the Keychain can't
    /// save, and of the file writes only the next one works: the edit's, not the undo's.
    private func makeFixture() throws -> Fixture {
        let fileURL = try XCTUnwrap(directory).appendingPathComponent("sources.json")
        let writes = WriteCountdown()
        let storage = SourceStorage(fileURL: fileURL) { data, url in
            if writes.nextWriteFails() { throw WriteFailure() }
            try data.write(to: url, options: .atomic)
        }
        let keychain = InMemoryCredentialStore()
        let manager = SourceManager(storage: storage, keychain: keychain)
        try manager.addSource(
            name: "Porch", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://192.0.2.1/s")), credentials: Self.oldLogin
        )
        writes.writesLeft = 1
        keychain.failSaves = true
        return Fixture(
            manager: manager, keychain: keychain, fileURL: fileURL, id: try XCTUnwrap(manager.sources.first?.id)
        )
    }

    private func savedSources(in url: URL) throws -> [CameraSource] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([CameraSource].self, from: Data(contentsOf: url))
    }

    private func edit(_ fixture: Fixture) -> EditSavedWithoutLoginError? {
        do {
            try fixture.manager.updateSource(
                id: fixture.id, name: "Garage", sourceType: Self.edited, credentials: .set(Self.newLogin)
            )
        } catch {
            return error as? EditSavedWithoutLoginError
        }
        return nil
    }

    func testAnEditThatCantBeUndoneIsSavedWithoutTheOldLogin() throws {
        let fixture = try makeFixture()
        var configChanges = 0
        fixture.manager.onSourceConfigChanged = { configChanges += 1 }

        let error = try XCTUnwrap(edit(fixture))

        XCTAssertTrue(error.oldLoginRemoved)
        let camera = try XCTUnwrap(fixture.manager.sources.first)
        XCTAssertEqual(camera.name, "Garage")
        XCTAssertEqual(camera.sourceType, Self.edited)
        let file = try savedSources(in: fixture.fileURL)
        XCTAssertEqual(file.map(\.name), ["Garage"], "the app holds what the file holds")
        XCTAssertEqual(file.map(\.sourceType), [Self.edited])
        XCTAssertNil(fixture.keychain.stored[fixture.id], "the old login must not go to the new address")
        XCTAssertNil(fixture.manager.credentials(for: fixture.id))
        XCTAssertFalse(fixture.manager.lastSaveFailed, "nothing is left unsaved")
        XCTAssertNil(fixture.manager.saveProblemMessage)
        XCTAssertEqual(configChanges, 1, "the stream reconnects to the camera as saved")
    }

    /// The Keychain can't remove the old login either: the error says it is still saved.
    func testTheErrorSaysWhenTheOldLoginCouldNotBeRemoved() throws {
        let fixture = try makeFixture()
        fixture.keychain.failDeletes = true

        let error = try XCTUnwrap(edit(fixture))

        XCTAssertFalse(error.oldLoginRemoved)
        XCTAssertEqual(fixture.manager.sources.first?.sourceType, Self.edited)
        XCTAssertEqual(fixture.keychain.stored[fixture.id], Self.oldLogin)
    }

    /// Shown in the edit form, which stays open with what was entered.
    func testTheErrorSaysTheCameraWasSavedWithoutItsLogin() {
        let removed = EditSavedWithoutLoginError(oldLoginRemoved: true).localizedDescription
        XCTAssertTrue(removed.contains("saved without its username and password"), removed)
        XCTAssertTrue(removed.contains("Enter them again"), removed)
        let kept = EditSavedWithoutLoginError(oldLoginRemoved: false).localizedDescription
        XCTAssertTrue(kept.contains("old ones couldn't be removed"), kept)
    }
}

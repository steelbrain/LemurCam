@testable import LemurCam
import XCTest

/// Adding, editing and removing a camera changed the Keychain before writing
/// `sources.json`, and a failed write only showed a warning: after a restart a removed
/// camera came back without its password, and an edited one had its old address with
/// its new password. A change whose write fails is now undone, in the app and in the
/// Keychain, and throws so the form or the list says it wasn't made. The storage's
/// writes are stubbed to fail; credentials go to an in-memory store.
@MainActor
internal final class SourceChangeWriteFailureTests: XCTestCase {
    /// Whether the stubbed file writes fail.
    private final class WriteSwitch {
        var fails = false
    }

    private struct WriteFailure: Error {}

    private static let oldLogin = SourceCredentials(username: "admin", password: "old-pw")
    private static let newLogin = SourceCredentials(username: "admin", password: "new-pw")

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
        let writes: WriteSwitch
        let fileURL: URL
        let saved: CameraSource
    }

    /// A manager holding one saved camera, "Porch" at rtsp://192.0.2.1/s, with
    /// `oldLogin` stored for it; then the file's writes start failing.
    private func makeFixture() throws -> Fixture {
        let fileURL = try XCTUnwrap(directory).appendingPathComponent("sources.json")
        let writes = WriteSwitch()
        let storage = SourceStorage(fileURL: fileURL) { data, url in
            if writes.fails { throw WriteFailure() }
            try data.write(to: url, options: .atomic)
        }
        let keychain = InMemoryCredentialStore()
        let manager = SourceManager(storage: storage, keychain: keychain)
        try manager.addSource(
            name: "Porch", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://192.0.2.1/s")), credentials: Self.oldLogin
        )
        let saved = try XCTUnwrap(manager.sources.first)
        manager.updateConnectionStatus(for: saved.id, status: .connected)
        writes.fails = true
        return Fixture(manager: manager, keychain: keychain, writes: writes, fileURL: fileURL, saved: saved)
    }

    private func savedSources(in url: URL) throws -> [CameraSource] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([CameraSource].self, from: Data(contentsOf: url))
    }

    private func assertThrowsWriteFailure(
        _ change: () throws -> Void, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try change(), file: file, line: line) { error in
            XCTAssertTrue(error is SourceFileSaveError, "\(error)", file: file, line: line)
        }
    }

    /// Nothing about the saved camera changed, in the app, the file or the Keychain,
    /// and no change was signalled.
    private func assertUnchanged(_ fixture: Fixture, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(fixture.manager.sources, [fixture.saved], file: file, line: line)
        XCTAssertEqual(fixture.manager.activeSourceID, fixture.saved.id, file: file, line: line)
        XCTAssertEqual(try savedSources(in: fixture.fileURL).map(\.id), [fixture.saved.id], file: file, line: line)
        XCTAssertEqual(fixture.keychain.stored, [fixture.saved.id: Self.oldLogin], file: file, line: line)
        XCTAssertFalse(fixture.manager.lastSaveFailed, "nothing is left unsaved", file: file, line: line)
        XCTAssertNil(fixture.manager.saveProblemMessage, file: file, line: line)
    }

    func testAFailedWriteKeepsARemovedCameraAndItsCredentials() throws {
        let fixture = try makeFixture()
        var configChanges = 0
        fixture.manager.onSourceConfigChanged = { configChanges += 1 }

        assertThrowsWriteFailure { try fixture.manager.removeSource(id: fixture.saved.id) }

        try assertUnchanged(fixture)
        XCTAssertEqual(fixture.manager.connectionStatuses[fixture.saved.id], .connected)
        XCTAssertEqual(configChanges, 0)
    }

    func testAFailedWriteUndoesAnEditAndKeepsTheOldCredentials() throws {
        let fixture = try makeFixture()
        let edited = SourceType.rtsp(RTSPSourceInfo(url: "rtsp://192.0.2.9/s"))

        assertThrowsWriteFailure {
            try fixture.manager.updateSource(
                id: fixture.saved.id, name: "Garage", sourceType: edited, credentials: .set(Self.newLogin)
            )
        }
        try assertUnchanged(fixture)

        assertThrowsWriteFailure {
            try fixture.manager.updateSource(
                id: fixture.saved.id, name: "Garage", sourceType: edited, credentials: .remove
            )
        }
        try assertUnchanged(fixture)

        // A login in the edited URL goes to the Keychain only once the file holds the URL.
        assertThrowsWriteFailure {
            try fixture.manager.updateSource(
                id: fixture.saved.id, name: "Garage",
                sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://admin:new-pw@192.0.2.9/s")), credentials: .keep
            )
        }
        try assertUnchanged(fixture)
    }

    func testAFailedWriteUndoesAnAddAndItsCredentials() throws {
        let fixture = try makeFixture()

        assertThrowsWriteFailure {
            try fixture.manager.addSource(
                name: "Garage", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://192.0.2.2/s")), credentials: Self.newLogin
            )
        }
        assertThrowsWriteFailure {
            try fixture.manager.addSource(
                name: "Shed", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://viewer:pw@192.0.2.3/s"))
            )
        }

        try assertUnchanged(fixture)
    }

    /// The first camera added becomes the active one; a failed add leaves none.
    func testAFailedFirstAddLeavesNoActiveCamera() throws {
        let fileURL = try XCTUnwrap(directory).appendingPathComponent("sources.json")
        let storage = SourceStorage(fileURL: fileURL) { _, _ in throw WriteFailure() }
        let keychain = InMemoryCredentialStore()
        let manager = SourceManager(storage: storage, keychain: keychain)

        assertThrowsWriteFailure {
            try manager.addSource(
                name: "Porch", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://192.0.2.1/s")), credentials: Self.oldLogin
            )
        }

        XCTAssertTrue(manager.sources.isEmpty)
        XCTAssertNil(manager.activeSourceID)
        XCTAssertTrue(keychain.stored.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    /// The file is written before the Keychain changes. When the new credentials then
    /// can't be stored, the file is put back: the camera keeps its old address with its
    /// old credentials.
    func testCredentialsThatCantBeStoredPutTheFileBack() throws {
        let fixture = try makeFixture()
        fixture.writes.fails = false
        fixture.keychain.failSaves = true

        XCTAssertThrowsError(try fixture.manager.updateSource(
            id: fixture.saved.id, name: "Garage", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://192.0.2.9/s")),
            credentials: .set(Self.newLogin)
        )) { error in
            XCTAssertTrue(error is CredentialSaveError, "\(error)")
        }

        try assertUnchanged(fixture)
        let file = try XCTUnwrap(savedSources(in: fixture.fileURL).first)
        XCTAssertEqual(file.name, "Porch")
        XCTAssertEqual(file.sourceType, fixture.saved.sourceType)
    }

    /// Once the file can be written again, the same change is made.
    func testTheChangeIsMadeOnceTheFileCanBeWritten() throws {
        let fixture = try makeFixture()
        assertThrowsWriteFailure { try fixture.manager.removeSource(id: fixture.saved.id) }

        fixture.writes.fails = false
        try fixture.manager.removeSource(id: fixture.saved.id)

        XCTAssertTrue(fixture.manager.sources.isEmpty)
        XCTAssertTrue(try savedSources(in: fixture.fileURL).isEmpty)
        XCTAssertTrue(fixture.keychain.stored.isEmpty)
    }

    /// Shown in the form, or in the alert when a removal fails. Names no file path.
    func testTheErrorSaysTheChangeWasNotMade() {
        let message = SourceFileSaveError().localizedDescription
        XCTAssertTrue(message.contains("couldn't save your cameras"), message)
        XCTAssertTrue(message.contains("wasn't made"), message)
        XCTAssertFalse(message.contains("/"), message)
    }
}

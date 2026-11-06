@testable import LemurCam
import XCTest

/// When the Keychain refused a save, adding or editing a camera only logged it and
/// went on: credentials typed into the URL had already been moved out of it, so the
/// stripped URL was saved and the only copy of the login was lost. Saving is now
/// refused with `CredentialSaveError`, nothing is changed, and the form shows the
/// message and stays open. Keychain access goes to an in-memory store that fails saves.
@MainActor
internal final class CredentialSaveFailureTests: XCTestCase {
    private var tempURL: URL?
    private var store: InMemoryCredentialStore?
    private var manager: SourceManager?
    private var savedActiveID: String?

    override func setUp() async throws {
        try await super.setUp()
        savedActiveID = UserDefaults.standard.string(forKey: LemurCamConfig.activeSourceKey)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("sources.json")
        tempURL = url
        let credentialStore = InMemoryCredentialStore()
        store = credentialStore
        manager = SourceManager(storage: SourceStorage(fileURL: url), keychain: credentialStore)
    }

    override func tearDown() async throws {
        if let savedActiveID {
            UserDefaults.standard.set(savedActiveID, forKey: LemurCamConfig.activeSourceKey)
        } else {
            UserDefaults.standard.removeObject(forKey: LemurCamConfig.activeSourceKey)
        }
        if let tempURL {
            try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent())
        }
        try await super.tearDown()
    }

    private func savedFile() throws -> Data? {
        try? Data(contentsOf: try XCTUnwrap(tempURL))
    }

    private func assertRefused(_ save: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try save(), file: file, line: line) { error in
            XCTAssertTrue(error is CredentialSaveError, "\(error)", file: file, line: line)
        }
    }

    // MARK: - Adding

    func testAddWithCredentialsIsRefusedAndAddsNothing() throws {
        let sourceManager = try XCTUnwrap(manager)
        try XCTUnwrap(store).failSaves = true
        var configChanges = 0
        sourceManager.onSourceConfigChanged = { configChanges += 1 }

        assertRefused {
            try sourceManager.addSource(
                name: "Porch", sourceType: .onvif(ONVIFSourceInfo(host: "192.0.2.9", port: 80)),
                credentials: SourceCredentials(username: "viewer", password: "pw")
            )
        }

        XCTAssertTrue(sourceManager.sources.isEmpty)
        XCTAssertNil(sourceManager.activeSourceID)
        XCTAssertNil(try savedFile(), "nothing may be written")
        XCTAssertEqual(configChanges, 0)
    }

    /// The reported loss: the login typed into the URL was moved out of it, the save
    /// failed, and the stripped URL was kept.
    func testAddOfURLWithCredentialsIsRefusedRatherThanStripped() throws {
        let sourceManager = try XCTUnwrap(manager)
        try XCTUnwrap(store).failSaves = true

        assertRefused {
            try sourceManager.addSource(name: "Cam", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://u:s3cret@192.0.2.8/s")))
        }

        XCTAssertTrue(sourceManager.sources.isEmpty)
        XCTAssertNil(try savedFile())
    }

    func testAddWithoutCredentialsNeedsNoKeychain() throws {
        let sourceManager = try XCTUnwrap(manager)
        let credentialStore = try XCTUnwrap(store)
        credentialStore.failSaves = true

        try sourceManager.addSource(name: "Cam", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://192.0.2.8/s")))

        XCTAssertEqual(sourceManager.sources.count, 1)
        XCTAssertTrue(credentialStore.writes.isEmpty)
    }

    // MARK: - Editing

    private func addCamera() throws -> (SourceManager, InMemoryCredentialStore, CameraSource) {
        let sourceManager = try XCTUnwrap(manager)
        let credentialStore = try XCTUnwrap(store)
        try sourceManager.addSource(
            name: "Cam", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://192.0.2.5/s")),
            credentials: SourceCredentials(username: "viewer", password: "pw")
        )
        credentialStore.failSaves = true
        return (sourceManager, credentialStore, try XCTUnwrap(sourceManager.sources.first))
    }

    func testEditWithNewCredentialsIsRefusedAndChangesNothing() throws {
        let (sourceManager, credentialStore, source) = try addCamera()
        let fileBefore = try savedFile()
        var configChanges = 0
        sourceManager.onSourceConfigChanged = { configChanges += 1 }

        assertRefused {
            try sourceManager.updateSource(
                id: source.id, name: "Renamed", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://192.0.2.6/s")),
                credentials: .set(SourceCredentials(username: "admin", password: "n3w"))
            )
        }

        XCTAssertEqual(sourceManager.sources.first, source)
        XCTAssertEqual(try savedFile(), fileBefore)
        XCTAssertEqual(credentialStore.stored[source.id], SourceCredentials(username: "viewer", password: "pw"))
        XCTAssertEqual(configChanges, 0)
    }

    func testEditOfURLWithCredentialsIsRefusedRatherThanStripped() throws {
        let (sourceManager, _, source) = try addCamera()

        assertRefused {
            try sourceManager.updateSource(
                id: source.id, name: "Cam", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://admin:n3w@192.0.2.5/s")),
                credentials: .keep
            )
        }

        XCTAssertEqual(sourceManager.sources.first, source)
    }

    /// Edits that store no new credentials still save.
    func testEditKeepingCredentialsStillSaves() throws {
        let (sourceManager, _, source) = try addCamera()

        try sourceManager.updateSource(
            id: source.id, name: "Renamed", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://192.0.2.5/s")),
            credentials: .keep
        )

        XCTAssertEqual(sourceManager.sources.first?.name, "Renamed")
    }

    func testMessageNamesTheKeychainAndNoCredentials() {
        let message = CredentialSaveError().localizedDescription
        XCTAssertTrue(message.contains("Keychain"), message)
        XCTAssertTrue(message.contains("wasn't saved"), message)
    }
}

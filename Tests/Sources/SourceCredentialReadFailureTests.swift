@testable import LemurCam
import XCTest

/// A Keychain read that fails used to look exactly like "no credentials": the edit
/// form opened with authentication off, and saving any change (even a rename)
/// deleted the camera's saved password. Reads now report failure separately, and the
/// form's save only removes credentials when the user turned authentication off on
/// credentials it could actually read.
@MainActor
internal final class SourceCredentialReadFailureTests: XCTestCase {
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

    private func addCamera() throws -> (SourceManager, InMemoryCredentialStore, UUID) {
        let sourceManager = try XCTUnwrap(manager)
        let credentialStore = try XCTUnwrap(store)
        sourceManager.addSource(
            name: "Cam", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://192.0.2.5/s")),
            credentials: SourceCredentials(username: "viewer", password: "pw")
        )
        return (sourceManager, credentialStore, try XCTUnwrap(sourceManager.sources.first).id)
    }

    // MARK: - Reads

    func testLoadCredentialsThrowsWhenTheKeychainCannotBeRead() throws {
        let (sourceManager, credentialStore, id) = try addCamera()
        credentialStore.failReads = true

        XCTAssertThrowsError(try sourceManager.loadCredentials(for: id))
        // The streaming path still gets a plain nil to connect with.
        XCTAssertNil(sourceManager.credentials(for: id))
    }

    func testLoadCredentialsReturnsNilWhenNoneSaved() throws {
        let sourceManager = try XCTUnwrap(manager)
        XCTAssertNil(try sourceManager.loadCredentials(for: UUID()))
    }

    // MARK: - Saving after a failed read

    /// The reported bug: rename a camera while its credentials can't be read. The
    /// form passes `.keep`, so nothing is deleted or overwritten.
    func testRenameAfterFailedReadKeepsStoredCredentials() throws {
        let (sourceManager, credentialStore, id) = try addCamera()
        credentialStore.failReads = true
        let writesBefore = credentialStore.writes

        let change = CredentialChange.fromForm(
            authenticationEnabled: false, username: "", password: "", storedCredentialsUnreadable: true
        )
        sourceManager.updateSource(
            id: id, name: "Renamed", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://192.0.2.5/s")),
            credentials: change
        )

        XCTAssertEqual(change, .keep)
        XCTAssertEqual(credentialStore.writes, writesBefore, "no save or delete may happen")
        XCTAssertEqual(credentialStore.stored[id], SourceCredentials(username: "viewer", password: "pw"))
    }

    func testRemoveDeletesAndSetSaves() throws {
        let (sourceManager, credentialStore, id) = try addCamera()
        let type = SourceType.rtsp(RTSPSourceInfo(url: "rtsp://192.0.2.5/s"))

        let fresh = SourceCredentials(username: "admin", password: "new")
        sourceManager.updateSource(id: id, name: "Cam", sourceType: type, credentials: .set(fresh))
        XCTAssertEqual(credentialStore.stored[id], fresh)

        sourceManager.updateSource(id: id, name: "Cam", sourceType: type, credentials: .remove)
        XCTAssertNil(credentialStore.stored[id])
    }

    /// Credentials typed into an RTSP URL while editing still reach the Keychain
    /// even when the form itself asks to keep what is stored.
    func testURLCredentialsOverrideKeep() throws {
        let (sourceManager, credentialStore, id) = try addCamera()
        sourceManager.updateSource(
            id: id, name: "Cam", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://bob:pa55@192.0.2.5/s")),
            credentials: .keep
        )
        XCTAssertEqual(credentialStore.stored[id], SourceCredentials(username: "bob", password: "pa55"))
    }

    /// The edit form fills its fields with the saved login and passes it back as
    /// `.set`. A new password pasted into the URL lost to it and was silently dropped;
    /// the URL's login is the newest input and now wins.
    func testURLCredentialsOverrideTheFormsSavedOnes() throws {
        let (sourceManager, credentialStore, id) = try addCamera()
        let shownInForm = try XCTUnwrap(credentialStore.stored[id])

        sourceManager.updateSource(
            id: id, name: "Cam", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://viewer:n3w-pw@192.0.2.5/s")),
            credentials: .set(shownInForm)
        )

        XCTAssertEqual(credentialStore.stored[id], SourceCredentials(username: "viewer", password: "n3w-pw"))
        XCTAssertEqual(sourceManager.sources.first?.sourceType, .rtsp(RTSPSourceInfo(url: "rtsp://192.0.2.5/s")))
    }

    /// Without a login in the URL the form's change applies as before.
    func testFormCredentialsApplyWhenTheURLHasNone() throws {
        let (sourceManager, credentialStore, id) = try addCamera()
        let typed = SourceCredentials(username: "admin", password: "typed")

        sourceManager.updateSource(
            id: id, name: "Cam", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://192.0.2.5/s")), credentials: .set(typed)
        )

        XCTAssertEqual(credentialStore.stored[id], typed)
    }

    // MARK: - Form decision

    func testFormDecision() {
        func decide(_ enabled: Bool, _ username: String, _ password: String, unreadable: Bool) -> CredentialChange {
            CredentialChange.fromForm(
                authenticationEnabled: enabled, username: username, password: password,
                storedCredentialsUnreadable: unreadable
            )
        }
        let entered = CredentialChange.set(SourceCredentials(username: "u", password: "pw"))
        XCTAssertEqual(decide(true, "u", "pw", unreadable: false), entered)
        XCTAssertEqual(decide(true, "u", "pw", unreadable: true), entered)
        // Authentication explicitly off (or on with both fields empty), credentials readable: remove them.
        XCTAssertEqual(decide(false, "u", "pw", unreadable: false), .remove)
        XCTAssertEqual(decide(true, "", "", unreadable: false), .remove)
        // Never remove what the form could not read.
        XCTAssertEqual(decide(false, "", "", unreadable: true), .keep)
        XCTAssertEqual(decide(true, "", "", unreadable: true), .keep)
    }
}

@testable import LemurCam
import XCTest

/// Editing a camera with a login in its RTSP URL replaced the saved credentials with
/// the URL's whole, even when the URL held only part of one: pasting
/// `rtsp://admin@192.0.2.6/s` to change the address saved an empty password, and
/// `rtsp://:pw@host` an empty user name. The URL now wins only for the parts it holds.
/// All Keychain access goes to an in-memory store.
@MainActor
internal final class PartialURLLoginTests: XCTestCase {
    private static let saved = SourceCredentials(username: "viewer", password: "pw")

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

    // MARK: - Which parts a URL holds

    func testLoginPartsTheURLHolds() {
        func login(_ url: String) -> URLLogin? {
            SourceCredentials.extractingLoginFromRTSPURL(url).login
        }
        XCTAssertEqual(login("rtsp://admin@192.0.2.6/s"), URLLogin(username: "admin", password: nil))
        XCTAssertEqual(login("rtsp://admin:@192.0.2.6/s"), URLLogin(username: "admin", password: ""))
        XCTAssertEqual(login("rtsp://:n3w@192.0.2.6/s"), URLLogin(username: "", password: "n3w"))
        XCTAssertEqual(login("rtsp://admin:n3w@192.0.2.6/s"), URLLogin(username: "admin", password: "n3w"))
        XCTAssertNil(login("rtsp://@192.0.2.6/s"))
        XCTAssertNil(login("rtsp://:@192.0.2.6/s"))
        XCTAssertNil(login("rtsp://192.0.2.6/s"))
        // Userinfo URLComponents can't read is split at its last `@`.
        XCTAssertEqual(login("rtsp://admin:Adm#1@192.0.2.6/s"), URLLogin(username: "admin", password: "Adm#1"))
        XCTAssertEqual(login("rtsp://admin:1234/5@192.0.2.6/s"), URLLogin(username: "admin", password: "1234/5"))
        XCTAssertEqual(SourceCredentials.extractingLoginFromRTSPURL("rtsp://admin@192.0.2.6/s").url,
                       "rtsp://192.0.2.6/s")
    }

    // MARK: - Merging with the form's change

    func testURLPartsWinAndTheFormSuppliesTheRest() {
        let form = CredentialChange.set(Self.saved)
        let unread: () -> SourceCredentials? = {
            XCTFail("the stored login is not needed")
            return nil
        }
        XCTAssertEqual(form.merging(URLLogin(username: "admin", password: nil), stored: unread),
                       .set(SourceCredentials(username: "admin", password: "pw")))
        XCTAssertEqual(form.merging(URLLogin(username: "", password: "n3w"), stored: unread),
                       .set(SourceCredentials(username: "viewer", password: "n3w")))
        // An empty password written out (`admin:@`) is the URL's.
        XCTAssertEqual(form.merging(URLLogin(username: "admin", password: ""), stored: unread),
                       .set(SourceCredentials(username: "admin", password: "")))
        XCTAssertEqual(form.merging(URLLogin(username: "admin", password: "n3w"), stored: unread),
                       .set(SourceCredentials(username: "admin", password: "n3w")))
        XCTAssertEqual(CredentialChange.keep.merging(URLLogin(username: "admin", password: "n3w"), stored: unread),
                       .set(SourceCredentials(username: "admin", password: "n3w")))
        XCTAssertEqual(form.merging(nil, stored: unread), form)
        XCTAssertEqual(CredentialChange.keep.merging(nil, stored: unread), .keep)
        XCTAssertEqual(CredentialChange.remove.merging(nil, stored: unread), .remove)
    }

    /// The form keeps what is stored when it could not show it; the stored part is
    /// used then. Authentication turned off leaves only the URL's part.
    func testURLPartsWithAFormThatKeepsOrRemoves() {
        let userOnly = URLLogin(username: "admin", password: nil)
        XCTAssertEqual(CredentialChange.keep.merging(userOnly) { Self.saved },
                       .set(SourceCredentials(username: "admin", password: "pw")))
        XCTAssertEqual(CredentialChange.keep.merging(userOnly) { nil },
                       .set(SourceCredentials(username: "admin", password: "")))
        XCTAssertEqual(CredentialChange.remove.merging(userOnly) { Self.saved },
                       .set(SourceCredentials(username: "admin", password: "")))
    }

    // MARK: - Saving an edit

    private func addCamera() throws -> (SourceManager, InMemoryCredentialStore, CameraSource) {
        let sourceManager = try XCTUnwrap(manager)
        let credentialStore = try XCTUnwrap(store)
        try sourceManager.addSource(
            name: "Cam", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://192.0.2.5/s")), credentials: Self.saved
        )
        return (sourceManager, credentialStore, try XCTUnwrap(sourceManager.sources.first))
    }

    private func edit(_ sourceManager: SourceManager, _ source: CameraSource, url: String,
                      credentials: CredentialChange = .set(PartialURLLoginTests.saved)) throws {
        try sourceManager.updateSource(
            id: source.id, name: source.name, sourceType: .rtsp(RTSPSourceInfo(url: url)), credentials: credentials
        )
    }

    /// The reported case: a URL with only a user name, pasted to change the address.
    func testUserNameOnlyInTheURLKeepsTheSavedPassword() throws {
        let (sourceManager, credentialStore, source) = try addCamera()

        try edit(sourceManager, source, url: "rtsp://admin@192.0.2.6/s")

        XCTAssertEqual(credentialStore.stored[source.id], SourceCredentials(username: "admin", password: "pw"))
        XCTAssertEqual(sourceManager.sources.first?.sourceType, .rtsp(RTSPSourceInfo(url: "rtsp://192.0.2.6/s")))
    }

    func testPasswordOnlyInTheURLKeepsTheSavedUserName() throws {
        let (sourceManager, credentialStore, source) = try addCamera()

        try edit(sourceManager, source, url: "rtsp://:n3w@192.0.2.6/s")

        XCTAssertEqual(credentialStore.stored[source.id], SourceCredentials(username: "viewer", password: "n3w"))
        XCTAssertEqual(sourceManager.sources.first?.sourceType, .rtsp(RTSPSourceInfo(url: "rtsp://192.0.2.6/s")))
    }

    /// Credentials the form could not read (`.keep`) supply the missing part.
    func testMissingPartComesFromTheStoredLoginWhenTheFormKeepsIt() throws {
        let (sourceManager, credentialStore, source) = try addCamera()

        try edit(sourceManager, source, url: "rtsp://admin@192.0.2.6/s", credentials: .keep)

        XCTAssertEqual(credentialStore.stored[source.id], SourceCredentials(username: "admin", password: "pw"))
    }

    /// When the stored part can't be read either, saving would replace it with an
    /// empty one: nothing is saved, and the form says so.
    func testUnreadableStoredLoginSavesNothing() throws {
        let (sourceManager, credentialStore, source) = try addCamera()
        credentialStore.failReads = true
        let writesBefore = credentialStore.writes

        XCTAssertThrowsError(try edit(sourceManager, source, url: "rtsp://admin@192.0.2.6/s", credentials: .keep)) {
            XCTAssertTrue($0 is CredentialSaveError)
        }

        XCTAssertEqual(credentialStore.writes, writesBefore)
        XCTAssertEqual(credentialStore.stored[source.id], Self.saved)
        XCTAssertEqual(sourceManager.sources.first, source)
    }
}

@testable import LemurCam
import XCTest

/// Credentials must not live in saved URLs. Two gaps are covered here: an RTSP URL
/// with an empty user name (`rtsp://:secret@host`) kept its password in
/// `sources.json` and the list subtitle, and a stream URI reported by an ONVIF camera
/// (some embed `admin:password@`) was saved verbatim. Sources saved by older versions
/// are cleaned up on load. All Keychain access goes to an in-memory store.
@MainActor
internal final class EmbeddedCredentialTests: XCTestCase {
    private var tempURL: URL?
    private var store: InMemoryCredentialStore?
    private var savedActiveID: String?

    override func setUp() async throws {
        try await super.setUp()
        savedActiveID = UserDefaults.standard.string(forKey: LemurCamConfig.activeSourceKey)
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("sources.json")
        store = InMemoryCredentialStore()
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

    private func makeManager() throws -> (SourceManager, InMemoryCredentialStore) {
        let credentialStore = try XCTUnwrap(store)
        return (SourceManager(storage: SourceStorage(fileURL: try XCTUnwrap(tempURL)), keychain: credentialStore),
                credentialStore)
    }

    private func savedJSON() throws -> String {
        try String(contentsOf: try XCTUnwrap(tempURL), encoding: .utf8)
    }

    // MARK: - Pure helpers

    func testPasswordWithEmptyUserNameIsExtracted() {
        let result = SourceCredentials.extractingFromRTSPURL("rtsp://:s3cret@192.0.2.8/stream")
        XCTAssertEqual(result.url, "rtsp://192.0.2.8/stream")
        XCTAssertEqual(result.credentials, SourceCredentials(username: "", password: "s3cret"))
    }

    func testEmptyUserInfoIsRemovedWithoutCredentials() {
        let result = SourceCredentials.extractingFromRTSPURL("rtsp://@192.0.2.8/stream")
        XCTAssertEqual(result.url, "rtsp://192.0.2.8/stream")
        XCTAssertNil(result.credentials)
    }

    func testStrippingUserInfoForDisplay() {
        XCTAssertEqual(SourceCredentials.strippingUserInfo(from: "rtsp://admin:pw@192.0.2.8:554/main"),
                       "rtsp://192.0.2.8:554/main")
        XCTAssertEqual(SourceCredentials.strippingUserInfo(from: "rtsp://192.0.2.8/main"), "rtsp://192.0.2.8/main")
    }

    func testFormKeepsPasswordWithEmptyUserName() {
        let change = CredentialChange.fromForm(
            authenticationEnabled: true, username: "", password: "s3cret", storedCredentialsUnreadable: false
        )
        XCTAssertEqual(change, .set(SourceCredentials(username: "", password: "s3cret")))
    }

    // MARK: - Persistence boundary

    func testRTSPPasswordWithEmptyUserNameGoesToKeychain() throws {
        let (manager, credentialStore) = try makeManager()
        try manager.addSource(name: "Cam", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://:s3cret@192.0.2.8/stream")))
        let source = try XCTUnwrap(manager.sources.first)

        XCTAssertEqual(source.sourceType, .rtsp(RTSPSourceInfo(url: "rtsp://192.0.2.8/stream")))
        XCTAssertEqual(credentialStore.stored[source.id], SourceCredentials(username: "", password: "s3cret"))
        XCTAssertFalse(try savedJSON().contains("s3cret"))
    }

    func testONVIFStreamURIIsSavedWithoutUserInfo() throws {
        let (manager, credentialStore) = try makeManager()
        try manager.addSource(name: "Porch", sourceType: .onvif(ONVIFSourceInfo(
            host: "192.0.2.9", port: 80, selectedProfileToken: "main",
            streamURI: "rtsp://admin:cam-pw@192.0.2.9:554/main"
        )))
        let source = try XCTUnwrap(manager.sources.first)

        guard case .onvif(let info) = source.sourceType else {
            XCTFail("expected ONVIF")
            return
        }
        XCTAssertEqual(info.streamURI, "rtsp://192.0.2.9:554/main")
        XCTAssertFalse(try savedJSON().contains("cam-pw"))
        XCTAssertTrue(credentialStore.writes.isEmpty, "a camera-reported login is not saved as the source's")

        try manager.updateSource(id: source.id, name: "Porch", sourceType: .onvif(ONVIFSourceInfo(
            host: "192.0.2.9", port: 80, selectedProfileToken: "main",
            streamURI: "rtsp://admin:cam-pw2@192.0.2.9:554/main"
        )), credentials: .keep)
        XCTAssertFalse(try savedJSON().contains("cam-pw2"))
    }

    // MARK: - Migration on load

    private func seed(_ sources: [CameraSource]) throws {
        SourceStorage(fileURL: try XCTUnwrap(tempURL)).save(sources)
    }

    func testLoadMovesEmbeddedCredentialsOutOfSavedURLs() throws {
        let rtsp = CameraSource(name: "Old RTSP", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://:s3cret@192.0.2.8/s")))
        let onvif = CameraSource(name: "Old ONVIF", sourceType: .onvif(ONVIFSourceInfo(
            host: "192.0.2.9", port: 80, streamURI: "rtsp://admin:cam-pw@192.0.2.9/main"
        )))
        try seed([rtsp, onvif])
        let (manager, credentialStore) = try makeManager()

        manager.load()

        XCTAssertEqual(manager.sources.first?.sourceType, .rtsp(RTSPSourceInfo(url: "rtsp://192.0.2.8/s")))
        XCTAssertEqual(credentialStore.stored[rtsp.id], SourceCredentials(username: "", password: "s3cret"))
        guard case .onvif(let info)? = manager.sources.last?.sourceType else {
            XCTFail("expected ONVIF")
            return
        }
        XCTAssertEqual(info.streamURI, "rtsp://192.0.2.9/main")
        let json = try savedJSON()
        XCTAssertFalse(json.contains("s3cret"))
        XCTAssertFalse(json.contains("cam-pw"))
    }

    /// Credentials the user saved in the Keychain win over ones left in an old URL.
    func testLoadKeepsExistingKeychainCredentials() throws {
        let source = CameraSource(name: "Cam", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://old:pw@192.0.2.8/s")))
        try seed([source])
        let (manager, credentialStore) = try makeManager()
        let saved = SourceCredentials(username: "current", password: "current-pw")
        try credentialStore.save(credentials: saved, for: source.id)

        manager.load()

        XCTAssertEqual(credentialStore.stored[source.id], saved)
        XCTAssertEqual(manager.sources.first?.sourceType, .rtsp(RTSPSourceInfo(url: "rtsp://192.0.2.8/s")))
    }

    /// Without a working Keychain the URL is the only copy of the credentials, so it
    /// is left alone.
    func testLoadLeavesURLWhenKeychainUnavailable() throws {
        let source = CameraSource(name: "Cam", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://u:pw@192.0.2.8/s")))
        try seed([source])
        let (manager, credentialStore) = try makeManager()
        credentialStore.failReads = true

        manager.load()

        XCTAssertEqual(manager.sources.first?.sourceType, source.sourceType)
        XCTAssertNil(credentialStore.stored[source.id])
    }

    func testLoadOfCleanSourcesWritesNothing() throws {
        try seed([CameraSource(name: "Cam", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://192.0.2.8/s")))])
        let before = try savedJSON()
        let (manager, credentialStore) = try makeManager()

        manager.load()

        XCTAssertEqual(try savedJSON(), before)
        XCTAssertTrue(credentialStore.writes.isEmpty)
    }
}

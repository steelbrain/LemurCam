@testable import LemurCam
import XCTest

/// Covers `SourceManager.load()` active-source selection and the credential
/// lifecycle on update — behaviors the existing `SourceManagerTests` does not
/// exercise. `load()` reads/writes the persisted active id in
/// `UserDefaults.standard`, so the original value is saved and restored to keep
/// the host app's real state untouched.
@MainActor
internal final class SourceManagerLifecycleTests: XCTestCase {
    private var tempURL: URL?
    private var manager: SourceManager?
    private var savedActiveID: String?

    override func setUp() async throws {
        try await super.setUp()
        savedActiveID = UserDefaults.standard.string(forKey: LemurCamConfig.activeSourceKey)
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("sources.json")
        guard let tempURL else { return }
        manager = SourceManager(storage: SourceStorage(fileURL: tempURL), keychain: KeychainService())
    }

    override func tearDown() async throws {
        if let sourceManager = manager {
            for source in sourceManager.sources { try? KeychainService().delete(for: source.id) }
        }
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

    private func seed(_ sources: [CameraSource]) throws {
        let url = try XCTUnwrap(tempURL)
        SourceStorage(fileURL: url).save(sources)
    }

    // MARK: - load() active-source selection

    func testLoadHonorsStoredActiveWhenPresent() throws {
        let sourceManager = try XCTUnwrap(manager)
        let first = CameraSource(name: "A", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://a")))
        let second = CameraSource(name: "B", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://b")))
        try seed([first, second])
        UserDefaults.standard.set(second.id.uuidString, forKey: LemurCamConfig.activeSourceKey)

        sourceManager.load()

        XCTAssertEqual(sourceManager.activeSourceID, second.id)
    }

    func testLoadFallsBackToFirstWhenStoredActiveMissing() throws {
        let sourceManager = try XCTUnwrap(manager)
        let first = CameraSource(name: "A", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://a")))
        let second = CameraSource(name: "B", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://b")))
        try seed([first, second])
        // A stored id that no longer matches any source must not stick.
        UserDefaults.standard.set(UUID().uuidString, forKey: LemurCamConfig.activeSourceKey)

        sourceManager.load()

        XCTAssertEqual(sourceManager.activeSourceID, first.id)
    }

    /// A stored value that is not a valid UUID string (corrupt defaults, or a format
    /// from an older build) must not trap `UUID(uuidString:)` — it degrades to the
    /// same first-source fallback as a missing key.
    func testLoadFallsBackToFirstWhenStoredActiveIsNotAUUID() throws {
        let sourceManager = try XCTUnwrap(manager)
        let first = CameraSource(name: "A", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://a")))
        try seed([first, CameraSource(name: "B", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://b")))])
        UserDefaults.standard.set("not-a-uuid", forKey: LemurCamConfig.activeSourceKey)

        sourceManager.load()

        XCTAssertEqual(sourceManager.activeSourceID, first.id)
    }

    func testLoadFallsBackToFirstWhenNoStoredActive() throws {
        let sourceManager = try XCTUnwrap(manager)
        let first = CameraSource(name: "A", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://a")))
        try seed([first, CameraSource(name: "B", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://b")))])
        UserDefaults.standard.removeObject(forKey: LemurCamConfig.activeSourceKey)

        sourceManager.load()

        XCTAssertEqual(sourceManager.activeSourceID, first.id)
    }

    func testLoadEmptyStorageHasNoActiveSource() throws {
        let sourceManager = try XCTUnwrap(manager)
        try seed([])

        sourceManager.load()

        XCTAssertTrue(sourceManager.sources.isEmpty)
        XCTAssertNil(sourceManager.activeSourceID)
    }

    func testLoadMarksEverySourceDisconnected() throws {
        let sourceManager = try XCTUnwrap(manager)
        let first = CameraSource(name: "A", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://a")))
        let second = CameraSource(name: "B", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://b")))
        try seed([first, second])

        sourceManager.load()

        XCTAssertEqual(sourceManager.connectionStatuses[first.id], .disconnected)
        XCTAssertEqual(sourceManager.connectionStatuses[second.id], .disconnected)
    }

    // MARK: - credential lifecycle on update

    func testUpdateWithNilCredentialsClearsStoredCredentials() throws {
        let sourceManager = try XCTUnwrap(manager)
        sourceManager.addSource(name: "Cam", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://a")),
                                credentials: SourceCredentials(username: "u", password: "p"))
        let id = try XCTUnwrap(sourceManager.sources.first).id

        sourceManager.updateSource(id: id, name: "Cam",
                                   sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://a")), credentials: nil)

        XCTAssertNil(sourceManager.credentials(for: id))
    }

    func testUpdateReplacesStoredCredentials() throws {
        let sourceManager = try XCTUnwrap(manager)
        sourceManager.addSource(name: "Cam", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://a")),
                                credentials: SourceCredentials(username: "old", password: "old"))
        let id = try XCTUnwrap(sourceManager.sources.first).id

        let fresh = SourceCredentials(username: "new", password: "new")
        sourceManager.updateSource(id: id, name: "Cam",
                                   sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://a")), credentials: fresh)

        XCTAssertEqual(sourceManager.credentials(for: id), fresh)
    }

    func testAddWithoutCredentialsStoresNothing() throws {
        let sourceManager = try XCTUnwrap(manager)
        sourceManager.addSource(name: "Cam", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://a")))
        let id = try XCTUnwrap(sourceManager.sources.first).id

        XCTAssertNil(sourceManager.credentials(for: id))
    }

    func testUpdateBumpsUpdatedAt() throws {
        let sourceManager = try XCTUnwrap(manager)
        sourceManager.addSource(name: "Cam", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://a")))
        let id = try XCTUnwrap(sourceManager.sources.first).id
        let before = try XCTUnwrap(sourceManager.sources.first).updatedAt

        Thread.sleep(forTimeInterval: 0.01)
        sourceManager.updateSource(id: id, name: "Renamed",
                                   sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://a")), credentials: nil)

        let after = try XCTUnwrap(sourceManager.sources.first).updatedAt
        XCTAssertGreaterThan(after, before)
    }

    func testUpdateUnknownSourceIsIgnored() throws {
        let sourceManager = try XCTUnwrap(manager)
        sourceManager.addSource(name: "Cam", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://a")))

        sourceManager.updateSource(id: UUID(), name: "Ghost",
                                   sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://x")), credentials: nil)

        XCTAssertEqual(sourceManager.sources.count, 1)
        XCTAssertEqual(sourceManager.sources.first?.name, "Cam")
    }

    // MARK: - Credentials never persist inside the source URL

    /// Helpers for asserting a stored `.rtsp` URL.
    private func storedRTSPURL(_ source: CameraSource?) -> String? {
        guard case .rtsp(let info)? = source?.sourceType else { return nil }
        return info.url
    }

    /// Adding an RTSP source whose URL embeds `user:pass@` must strip the credentials
    /// out of the persisted URL and route them to the Keychain instead. Before the fix,
    /// the edit form's raw URL field let credentials reach `sources.json` in cleartext.
    func testAddStripsCredentialsFromRTSPURLIntoKeychain() throws {
        let sourceManager = try XCTUnwrap(manager)
        sourceManager.addSource(
            name: "Cam",
            sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://user:pa55@192.168.1.9:554/stream"))
        )
        let source = try XCTUnwrap(sourceManager.sources.first)

        XCTAssertEqual(storedRTSPURL(source), "rtsp://192.168.1.9:554/stream")
        XCTAssertEqual(sourceManager.credentials(for: source.id),
                       SourceCredentials(username: "user", password: "pa55"))
    }

    /// The persisted JSON itself must not contain the password — re-load from disk and
    /// confirm the stored URL is credential-free (the on-disk artifact, not just memory).
    func testCredentialsAreAbsentFromPersistedJSON() throws {
        let sourceManager = try XCTUnwrap(manager)
        sourceManager.addSource(
            name: "Cam",
            sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://admin:secret@cam.local/h264"))
        )
        let url = try XCTUnwrap(tempURL)
        let raw = try String(contentsOf: url, encoding: .utf8)

        XCTAssertFalse(raw.contains("secret"), "password leaked into persisted JSON")
        XCTAssertFalse(raw.contains("admin@"), "username leaked into persisted JSON")
        // JSONEncoder escapes "/" as "\/", so assert on the credential-free host substring.
        XCTAssertTrue(raw.contains("cam.local"), "host should still be persisted")
    }

    /// Editing a source and pasting a credential-bearing URL is the path the audit
    /// flagged: the edit form does no stripping, so the persistence layer must.
    func testUpdateStripsCredentialsFromRTSPURL() throws {
        let sourceManager = try XCTUnwrap(manager)
        sourceManager.addSource(name: "Cam", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://cam/old")))
        let id = try XCTUnwrap(sourceManager.sources.first).id

        sourceManager.updateSource(
            id: id, name: "Cam",
            sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://bob:hunter2@cam/new")),
            credentials: nil
        )
        let source = try XCTUnwrap(sourceManager.sources.first)

        XCTAssertEqual(storedRTSPURL(source), "rtsp://cam/new")
        XCTAssertEqual(sourceManager.credentials(for: id),
                       SourceCredentials(username: "bob", password: "hunter2"))
    }

    /// An explicit credentials object (from the Username/Password fields) takes
    /// precedence over anything in the URL, and the URL is still stripped clean.
    func testExplicitCredentialsWinOverURLCredentials() throws {
        let sourceManager = try XCTUnwrap(manager)
        sourceManager.addSource(
            name: "Cam",
            sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://urluser:urlpass@cam/s")),
            credentials: SourceCredentials(username: "field", password: "fieldpass")
        )
        let source = try XCTUnwrap(sourceManager.sources.first)

        XCTAssertEqual(storedRTSPURL(source), "rtsp://cam/s")
        XCTAssertEqual(sourceManager.credentials(for: source.id),
                       SourceCredentials(username: "field", password: "fieldpass"))
    }

    // MARK: - extractingFromRTSPURL (pure helper)

    func testExtractCredentialsSplitsUserAndPassword() {
        let result = SourceCredentials.extractingFromRTSPURL("rtsp://u:p@host:554/path")
        XCTAssertEqual(result.url, "rtsp://host:554/path")
        XCTAssertEqual(result.credentials, SourceCredentials(username: "u", password: "p"))
    }

    func testExtractCredentialsHandlesUsernameOnly() {
        let result = SourceCredentials.extractingFromRTSPURL("rtsp://u@host/path")
        XCTAssertEqual(result.url, "rtsp://host/path")
        XCTAssertEqual(result.credentials, SourceCredentials(username: "u", password: ""))
    }

    func testExtractCredentialsLeavesCleanURLUntouched() {
        let result = SourceCredentials.extractingFromRTSPURL("rtsp://host:554/path")
        XCTAssertEqual(result.url, "rtsp://host:554/path")
        XCTAssertNil(result.credentials)
    }

    /// An unparseable URL is returned unchanged rather than crashing or partially
    /// mangling it; there is nothing the splitter can safely strip.
    func testExtractCredentialsReturnsUnparseableUnchanged() {
        let result = SourceCredentials.extractingFromRTSPURL("not a url")
        XCTAssertEqual(result.url, "not a url")
        XCTAssertNil(result.credentials)
    }
}

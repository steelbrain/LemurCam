@testable import LemurCam
import XCTest

/// `URLComponents` misreads userinfo with a raw `/`, `?`, `#` or `@`. A camera-reported
/// stream URI such as `rtsp://admin:Admin#123@192.168.1.5/stream` doesn't parse at
/// all, so its password was shown in the form and saved verbatim; a typed
/// `rtsp://admin:1234/5@cam/stream` parses as host `admin`, port 1234, passed
/// validation and was saved and shown in the source list. Such URLs are now split at
/// their last `@`, typed ones are rejected with an explanation, and saved ones are
/// cleaned up on load without losing credentials. Keychain access goes to an
/// in-memory store.
@MainActor
internal final class AmbiguousUserInfoTests: XCTestCase {
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

    private func seed(_ sources: [CameraSource]) throws {
        SourceStorage(fileURL: try XCTUnwrap(tempURL)).save(sources)
    }

    // MARK: - Splitting

    func testHashOrQuestionMarkInPasswordIsSplitAtTheLastAt() {
        let hash = SourceCredentials.extractingFromRTSPURL("rtsp://admin:Admin#123@192.168.1.5:554/stream")
        XCTAssertEqual(hash.url, "rtsp://192.168.1.5:554/stream")
        XCTAssertEqual(hash.credentials, SourceCredentials(username: "admin", password: "Admin#123"))

        let question = SourceCredentials.extractingFromRTSPURL("rtsp://admin:pa?ss@192.168.1.5/s")
        XCTAssertEqual(question.url, "rtsp://192.168.1.5/s")
        XCTAssertEqual(question.credentials, SourceCredentials(username: "admin", password: "pa?ss"))
    }

    func testSlashInPasswordIsSplitAtTheLastAt() {
        let result = SourceCredentials.extractingFromRTSPURL("rtsp://admin:1234/5@cam/stream")
        XCTAssertEqual(result.url, "rtsp://cam/stream")
        XCTAssertEqual(result.credentials, SourceCredentials(username: "admin", password: "1234/5"))
    }

    func testPercentEncodingIsDecodedInAnAmbiguousSplit() {
        let result = SourceCredentials.extractingFromRTSPURL("rtsp://ad%20min:p%40ss#1@cam/s")
        XCTAssertEqual(result.credentials, SourceCredentials(username: "ad min", password: "p@ss#1"))
        let raw = SourceCredentials.extractingFromRTSPURL("rtsp://admin:50%off#@cam/s")
        XCTAssertEqual(raw.credentials?.password, "50%off#", "invalid percent-encoding is kept as written")
    }

    func testDisplayStripsAmbiguousUserInfo() {
        XCTAssertEqual(SourceCredentials.strippingUserInfo(from: "rtsp://admin:Admin#123@192.168.1.5:554/stream"),
                       "rtsp://192.168.1.5:554/stream")
        XCTAssertEqual(SourceCredentials.strippingUserInfo(from: "rtsp://admin:1234/5@cam/stream"), "rtsp://cam/stream")
    }

    /// URLs `URLComponents` reads correctly keep their existing handling.
    func testUnambiguousURLsAreNotFlagged() {
        let unambiguous = [
            "rtsp://admin:pw@cam:554/s", "rtsp://admin:p@ss@cam/s", "rtsp://cam/live@main",
            "rtsp://[::1]:554/s@x", "rtsp://cam/s?user=a@b", "rtsp://cam:554/s"
        ]
        for url in unambiguous {
            XCTAssertFalse(SourceCredentials.hasAmbiguousUserInfo(url), url)
        }
        XCTAssertEqual(SourceCredentials.extractingFromRTSPURL("rtsp://admin:p@ss@cam/s").credentials,
                       SourceCredentials(username: "admin", password: "p@ss"))
        XCTAssertEqual(SourceCredentials.extractingFromRTSPURL("rtsp://cam/live@main").url, "rtsp://cam/live@main")
    }

    /// IPCamKit refuses these too: an `@` after the host, with a port or userinfo
    /// before it.
    func testAmbiguousURLsAreFlagged() {
        let ambiguous = [
            "rtsp://admin:Admin#123@192.168.1.5/s", "rtsp://admin:1234/5@cam/stream",
            "rtsp://cam:554/live@main", "rtsp://admin:pw@cam/s@x", "rtsp://corp/alice:pw@cam/"
        ]
        for url in ambiguous {
            XCTAssertTrue(SourceCredentials.hasAmbiguousUserInfo(url), url)
        }
    }

    // MARK: - Typed URLs

    func testFormRejectsAmbiguousURLsWithAnExplanation() {
        XCTAssertEqual(RTSPURLInput.problem(with: "rtsp://admin:1234/5@cam/stream"),
                       RTSPURLInput.ambiguousUserInfoMessage)
        XCTAssertEqual(RTSPURLInput.problem(with: "rtsp://admin:Admin#123@192.168.1.5/s"),
                       RTSPURLInput.ambiguousUserInfoMessage)
        XCTAssertNil(RTSPURLInput.problem(with: "rtsp://admin:pw@192.168.1.5:554/s"))
        XCTAssertNil(RTSPURLInput.problem(with: "rtsps://cam.local/s"))
        XCTAssertEqual(RTSPURLInput.problem(with: "http://cam/s"), RTSPURLInput.invalidMessage)
        XCTAssertEqual(RTSPURLInput.problem(with: "rtsp://"), RTSPURLInput.invalidMessage)
        XCTAssertEqual(RTSPURLInput.problem(with: ""), RTSPURLInput.invalidMessage)
    }

    // MARK: - Saving

    func testCameraReportedStreamURIIsSavedWithoutAmbiguousUserInfo() throws {
        let (manager, credentialStore) = try makeManager()
        try manager.addSource(name: "Porch", sourceType: .onvif(ONVIFSourceInfo(
            host: "192.168.1.5", port: 80, selectedProfileToken: "main",
            streamURI: "rtsp://admin:Cam#pw1@192.168.1.5:554/stream"
        )))

        guard case .onvif(let info)? = manager.sources.first?.sourceType else {
            XCTFail("expected ONVIF")
            return
        }
        XCTAssertEqual(info.streamURI, "rtsp://192.168.1.5:554/stream")
        XCTAssertFalse(try savedJSON().contains("Cam#pw1"))
        XCTAssertTrue(credentialStore.writes.isEmpty, "a camera-reported login is not saved as the source's")
    }

    // MARK: - Migration on load

    func testLoadMovesAmbiguousUserInfoToTheKeychain() throws {
        let rtsp = CameraSource(name: "Old", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://admin:s3cr/et@cam/s")))
        let onvif = CameraSource(name: "Cam", sourceType: .onvif(ONVIFSourceInfo(
            host: "192.168.1.5", port: 80, streamURI: "rtsp://admin:Cam#pw1@192.168.1.5/main"
        )))
        try seed([rtsp, onvif])
        let (manager, credentialStore) = try makeManager()

        manager.load()

        XCTAssertEqual(manager.sources.first?.sourceType, .rtsp(RTSPSourceInfo(url: "rtsp://cam/s")))
        XCTAssertEqual(credentialStore.stored[rtsp.id], SourceCredentials(username: "admin", password: "s3cr/et"))
        guard case .onvif(let info)? = manager.sources.last?.sourceType else {
            XCTFail("expected ONVIF")
            return
        }
        XCTAssertEqual(info.streamURI, "rtsp://192.168.1.5/main")
        let json = try savedJSON()
        XCTAssertFalse(json.contains("s3cr"))
        XCTAssertFalse(json.contains("Cam#pw1"))
    }

    /// Without a working Keychain the URL is the only copy of the credentials.
    func testLoadLeavesAmbiguousURLWhenKeychainUnavailable() throws {
        let source = CameraSource(name: "Cam", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://admin:1234/5@cam/s")))
        try seed([source])
        let (manager, credentialStore) = try makeManager()
        credentialStore.failReads = true

        manager.load()

        XCTAssertEqual(manager.sources.first?.sourceType, source.sourceType)
        XCTAssertTrue(credentialStore.writes.isEmpty)
    }

    /// A login in the query with an `@` in its password still parses as an address.
    /// Splitting it at the last `@` would leave `rtsp://ss&channel=1`, so the saved
    /// URL is kept for the user to correct, whatever the Keychain holds. An ONVIF
    /// stream URI on the camera's own host or an IP address has the `@` written `%40`
    /// instead (`ONVIFUnsplitURILoginTests`): there is no URL field to correct it in.
    func testLoadLeavesAmbiguousURLThatParsesAsAnAddress() throws {
        let url = "rtsp://192.168.1.5:554/user=admin&password=p@ss&channel=1"
        let rtsp = CameraSource(name: "DVR", sourceType: .rtsp(RTSPSourceInfo(url: url)))
        let onvif = CameraSource(name: "Cam", sourceType: .onvif(ONVIFSourceInfo(
            host: "192.168.1.5", port: 80, streamURI: url
        )))
        try seed([rtsp, onvif])
        let (manager, credentialStore) = try makeManager()

        manager.load()

        let escaped = SourceType.onvif(ONVIFSourceInfo(
            host: "192.168.1.5", port: 80, streamURI: "rtsp://192.168.1.5:554/user=admin&password=p%40ss&channel=1"
        ))
        XCTAssertEqual(manager.sources.map(\.sourceType), [rtsp.sourceType, escaped])
        XCTAssertTrue(credentialStore.writes.isEmpty)
    }

    /// v1.5 saved a reported stream URI as it came, and loading left any ambiguous URI
    /// that parses as it was, so its login stayed in the file. The rule a reported URI
    /// is saved and connected to by decides now: split at the last `@` when the camera's
    /// host follows it, or the userinfo `URLComponents` reads taken out. The login is
    /// dropped, not moved to the Keychain: it is the camera's, re-read on every connect.
    func testLoadDropsTheLoginOfAnAmbiguousONVIFStreamURIThatParses() throws {
        let cases = [
            (saved: "rtsp://admin:1234/5@192.168.1.5/s", cleaned: "rtsp://192.168.1.5/s"),
            (saved: "rtsp://admin:pw@192.168.1.5/s?a=b@c", cleaned: "rtsp://192.168.1.5/s?a=b@c")
        ]
        for (saved, _) in cases {
            XCTAssertTrue(SourceCredentials.hasAmbiguousUserInfo(saved), saved)
            XCTAssertNotNil(URLComponents(string: saved), saved)
        }
        try seed(cases.map { saved, _ in
            CameraSource(name: "Cam", sourceType: .onvif(ONVIFSourceInfo(
                host: "192.168.1.5", port: 80, streamURI: saved
            )))
        })
        let (manager, credentialStore) = try makeManager()

        manager.load()

        let uris = manager.sources.map { source -> String? in
            guard case .onvif(let info) = source.sourceType else { return nil }
            return info.streamURI
        }
        XCTAssertEqual(uris, cases.map(\.cleaned))
        XCTAssertTrue(credentialStore.writes.isEmpty, "a camera-reported login is not saved as the source's")
        XCTAssertFalse(try savedJSON().contains("admin"))
    }

    /// With other credentials saved, the part before the last `@` can't be moved, and
    /// it may be part of the address: the URL is left for the user to correct.
    func testLoadLeavesAmbiguousURLWhenOtherCredentialsAreSaved() throws {
        let source = CameraSource(name: "Cam", sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://cam:554/live@main")))
        try seed([source])
        let (manager, credentialStore) = try makeManager()
        let saved = SourceCredentials(username: "viewer", password: "pw")
        try credentialStore.save(credentials: saved, for: source.id)

        manager.load()

        XCTAssertEqual(manager.sources.first?.sourceType, source.sourceType)
        XCTAssertEqual(credentialStore.stored[source.id], saved)
    }
}

@testable import LemurCam
import XCTest

/// A user name or password whose escapes, decoded once, are not UTF-8 (`%A3`, `%E9`,
/// `%FF`) read as none once each character `URLComponents` encodes was written as an
/// escape before parsing: `rtsp://admin:100%Off%A3@192.168.1.10/live` lost its
/// password, and `rtsp://op%E9rateur|1:pw%E9|@192.168.1.10/live` was saved with its
/// login in the cameras file and shown in the camera list. Such a part is now read as
/// written, as `URLComponents(string:)` and IPCamKit read one that holds a character
/// they encode. Keychain access goes to an in-memory store.
@MainActor
internal final class NonUTF8LoginTests: XCTestCase {
    private var directory: URL?
    private var savedActiveID: String?

    override func setUp() async throws {
        try await super.setUp()
        // `addSource` saves the active camera in the host app's standard defaults.
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

    private func login(_ username: String, _ password: String) -> SourceCredentials {
        SourceCredentials(username: username, password: password)
    }

    /// The reported cases. In the last two nothing is a character `URLComponents`
    /// encodes, so IPCamKit refuses the URL as typed; the login is still taken out.
    func testAUserNameOrPasswordWhoseEscapesArentUTF8IsReadAsWritten() {
        let cases: [(url: String, login: SourceCredentials)] = [
            ("rtsp://admin:100%Off%A3@192.168.1.10/live", login("admin", "100%Off%A3")),
            ("rtsp://op%E9rateur|1:pw%E9|@192.168.1.10/live", login("op%E9rateur|1", "pw%E9|")),
            ("rtsp://%FF:pw%FF@192.168.1.10/live", login("%FF", "pw%FF")),
            ("rtsp://admin:pw%E9@192.168.1.10/live", login("admin", "pw%E9"))
        ]
        for (url, expected) in cases {
            XCTAssertNil(RTSPURLInput.problem(with: url), url)
            let extracted = SourceCredentials.extractingLoginFromRTSPURL(url)
            XCTAssertEqual(extracted.url, "rtsp://192.168.1.10/live", url)
            XCTAssertEqual(extracted.login?.credentials, expected, url)
            XCTAssertEqual(DisplayedURL.redacted(url), "rtsp://192.168.1.10/live", url)
        }
    }

    /// Each part is read on its own, and all of its escapes as written, as
    /// `URLComponents(string:)` reads a part. A stray byte next to a non-ASCII
    /// character keeps the character.
    func testEachPartIsReadOnItsOwn() {
        let cases: [(url: String, login: SourceCredentials)] = [
            ("rtsp://j%C3%BCrgen:pw%E9@cam/x", login("jürgen", "pw%E9")),
            ("rtsp://op%E9rateur:p%40ss@cam/x", login("op%E9rateur", "p@ss")),
            ("rtsp://admin:p%40ss%FF@cam/x", login("admin", "p%40ss%FF")),
            ("rtsp://admin:%C3é@cam/x", login("admin", "%C3é"))
        ]
        for (url, expected) in cases {
            XCTAssertEqual(SourceCredentials.extractingLoginFromRTSPURL(url).login?.credentials, expected, url)
        }
    }

    /// Only the `%` of such a part is written as an escape; the rest of the URL keeps
    /// its escapes.
    func testTheEncodingEscapesThePercentSignsOfSuchAPartOnly() {
        let encode = URLComponents.percentEncodingForParsing
        XCTAssertEqual(
            encode("rtsp://op%E9rateur|1:pw%E9|@cam/s%E9?q=%FF"), "rtsp://op%25E9rateur%7C1:pw%25E9%7C@cam/s%E9?q=%FF"
        )
        XCTAssertEqual(encode("rtsp://j%C3%BCrgen:pw%E9@cam/x"), "rtsp://j%C3%BCrgen:pw%25E9@cam/x")
        XCTAssertEqual(encode("rtsp://%C3%A9:pw@cam/x"), "rtsp://%C3%A9:pw@cam/x")
    }

    func testAnAddedCameraKeepsSuchALoginOutOfTheFile() throws {
        let fileURL = try XCTUnwrap(directory).appendingPathComponent("sources.json")
        let keychain = InMemoryCredentialStore()
        let manager = SourceManager(storage: SourceStorage(fileURL: fileURL), keychain: keychain)

        try manager.addSource(name: "Porch", sourceType: .rtsp(RTSPSourceInfo(
            url: "rtsp://op%E9rateur|1:pw%E9|@192.168.1.10/live"
        )))

        let source = try XCTUnwrap(manager.sources.first)
        XCTAssertEqual(source.sourceType, .rtsp(RTSPSourceInfo(url: "rtsp://192.168.1.10/live")))
        XCTAssertEqual(keychain.stored[source.id], login("op%E9rateur|1", "pw%E9|"))
        let file = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertFalse(file.contains("rateur"), file)
    }

    /// v1.5 saved a URL with its login, and loading left such a login in it.
    func testSuchALoginLeftInASavedURLIsMovedOnLoad() throws {
        let fileURL = try XCTUnwrap(directory).appendingPathComponent("sources.json")
        let source = CameraSource(name: "Porch", sourceType: .rtsp(RTSPSourceInfo(
            url: "rtsp://%FF:pw%FF@192.168.1.10/live"
        )))
        SourceStorage(fileURL: fileURL).save([source])
        let keychain = InMemoryCredentialStore()
        let manager = SourceManager(storage: SourceStorage(fileURL: fileURL), keychain: keychain)

        manager.load()

        XCTAssertEqual(manager.sources.first?.sourceType, .rtsp(RTSPSourceInfo(url: "rtsp://192.168.1.10/live")))
        XCTAssertEqual(keychain.stored[source.id], login("%FF", "pw%FF"))
        let file = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertFalse(file.contains("pw%FF"), file)
    }

    /// A stream URI an ONVIF camera reported goes the same way: what is saved is what
    /// is connected to, and the login connected with is the one it holds.
    func testAReportedURIsSuchLoginIsReadAsWritten() {
        let uri = "rtsp://admin:100%Off%A3@192.0.2.5/live"
        let target = StreamCoordinator.connectionTarget(
            forResolvedURI: uri, reportedBy: "192.0.2.5", savedCredentials: nil
        )
        XCTAssertEqual(target.url, "rtsp://192.0.2.5/live")
        XCTAssertEqual(target.credentials, login("admin", "100%Off%A3"))
        assertConnectsWhereSaved(uri)
    }
}

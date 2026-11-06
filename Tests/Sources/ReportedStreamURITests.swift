@testable import LemurCam
import XCTest

/// A stream URI an ONVIF camera reports is saved as the camera's fallback without
/// the login some cameras put in its userinfo. It used to be cut at its last `@`
/// whenever that `@` came after the host, so a login in the query
/// (`?password=Adm1n@2024`) was saved as `rtsp://2024`. It was then cut there only
/// when the host after that `@` was the camera's, so a camera saved by a name
/// (`frontdoor.local`) that reports its IP address with a `#` in the password was
/// saved without a fallback and refused on every connect. It is now cut there when no
/// `/` or `?` comes before that `@`, and otherwise only when the host after it is the
/// camera's, whether or not `URLComponents` can read it, by the rule the stream is
/// connected to by as well. All Keychain access goes to an in-memory store.
@MainActor
internal final class ReportedStreamURITests: XCTestCase {
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

    private func splits(_ uri: String, host: String = "192.0.2.5") -> Bool {
        SourceCredentials.splitsAtLastAt(reportedURI: uri, onvifHost: host)
    }

    // MARK: - The split rule

    /// Not split wherever it points any more: with `?password=p@ss word`, which some
    /// macOS versions can't parse, the rest of the password was taken for the host.
    func testAURIURLComponentsCantReadIsSplitOnlyWhenTheHostAfterTheLastAtSignIsTheCamera() {
        XCTAssertTrue(splits("rtsp://user:p#ss@192.0.2.5/s"))
        XCTAssertTrue(splits("rtsp://user:p?ss@192.0.2.5/s"))
        XCTAssertFalse(splits("rtsp://user:p?ss@192.0.2.5/s", host: "192.0.2.9"), "a `?` before the `@`")
        XCTAssertFalse(splits("rtsp://192.0.2.5:554:1/live?password=p@ss word"))
        // The host is read by hand: up to a port, path, query or fragment, or a
        // bracketed IPv6 literal. IP literals compare by value, names without case.
        XCTAssertTrue(splits("rtsp://user:p#ss@192.0.2.5"))
        XCTAssertTrue(splits("rtsp://user:p#ss@192.0.2.5?x=1"))
        XCTAssertTrue(splits("rtsp://user:p#ss@CAM.example:554/s", host: "cam.example"))
        XCTAssertTrue(splits("rtsp://user:p#ss@[fe80::1]:554/s", host: "fe80:0::1"))
        XCTAssertTrue(splits("rtsp://user:p#ss@[::ffff:192.0.2.5]/s"))
        XCTAssertFalse(splits("rtsp://user:p#ss@[fe80::1:554/s", host: "fe80::1"), "no closing bracket")
        XCTAssertFalse(splits("rtsp://user:p#ss@:554/s"), "no host")
    }

    /// With no `/` or `?` before the last `@`, that `@` can only end the login, so the
    /// URI is split wherever the camera is: one saved by a name usually reports its IP
    /// address. A `?` or a `/` before it still needs the camera's own host after it.
    func testALoginEndingBeforeAnyPathOrQueryIsSplitForAnyHost() {
        XCTAssertNil(URLComponents(string: "rtsp://admin:p#ss@192.168.1.20/s"))
        XCTAssertTrue(splits("rtsp://admin:p#ss@192.168.1.20/s", host: "frontdoor.local"))
        XCTAssertTrue(splits("rtsp://user:p#ss@192.0.2.9/s"))
        XCTAssertTrue(splits("rtsp://us@er:p#ss@192.0.2.9/s"), "an `@` in the user name")
        XCTAssertNotNil(URLComponents(string: "rtsp://user:1234#ab@192.168.1.20/s"))
        XCTAssertTrue(splits("rtsp://user:1234#ab@192.168.1.20/s", host: "frontdoor.local"))

        XCTAssertFalse(splits("rtsp://user:p?ss@192.168.1.20/s", host: "frontdoor.local"))
        XCTAssertFalse(splits("rtsp://admin:12/34@192.168.1.20/s", host: "frontdoor.local"))
        for uri in [
            "rtsp://192.168.1.20:554/live?password=p@ss word", "rtsp://192.168.1.20:554:1/live?password=p@ss word",
            "rtsp://192.168.1.20:554/live?password=Adm1n@2024"
        ] {
            XCTAssertFalse(splits(uri, host: "frontdoor.local"), uri)
            XCTAssertFalse(splits(uri, host: "192.168.1.20"), uri)
        }
        // Still no host after the `@`: not split.
        XCTAssertFalse(splits("rtsp://user:p#ss@[fe80::1:554/s", host: "frontdoor.local"))
    }

    /// IP literals compare by value for a URI `URLComponents` reads too.
    func testTheCameraIsMatchedByValue() {
        XCTAssertTrue(splits("rtsp://admin:1234/5@[::ffff:192.0.2.5]/s"))
        XCTAssertTrue(splits("rtsp://admin:1234/5@[FE80::1]/s", host: "fe80:0:0::1"))
    }

    /// What is saved and what is connected to follow one rule: a URI split for one is
    /// split the same way for the other.
    func testSavingAndConnectingAgree() {
        let uris = [
            "rtsp://user:p#ss@192.0.2.5/s", "rtsp://user:p#ss@192.0.2.9/s", "rtsp://admin:1234/5@192.0.2.5/s",
            "rtsp://admin:1234/5@192.0.2.9/s", "rtsp://192.0.2.5:554/live?password=Adm1n@2024",
            "rtsp://192.0.2.5:554/live?password=p@ss word", "rtsp://192.0.2.5:554:1/live?password=p@ss word",
            "rtsp://admin:pw@192.0.2.5/s", "rtsp://user:1234#ab@192.0.2.9/s", "rtsp://user:p?ss@192.0.2.9/s"
        ]
        for uri in uris {
            let connected = StreamCoordinator.connectionTarget(
                forResolvedURI: uri, reportedBy: "192.0.2.5", savedCredentials: nil
            )
            let saved = SourceCredentials.strippingUserInfo(fromReportedURI: uri, onvifHost: "192.0.2.5")
            if splits(uri) {
                XCTAssertEqual(connected.url, saved, uri)
                XCTAssertNotEqual(connected.url, uri, uri)
            } else {
                XCTAssertEqual(connected.url, uri, uri)
            }
        }
    }

    func testAReadableURIIsSplitOnlyWhenTheHostAfterTheLastAtSignIsTheCamera() {
        XCTAssertTrue(splits("rtsp://admin:1234/5@192.0.2.5/s"))
        XCTAssertTrue(splits("rtsp://admin:1234/5@Cam.local/s", host: "cam.LOCAL"))
        XCTAssertFalse(splits("rtsp://admin:1234/5@192.0.2.5/s", host: "192.0.2.6"))
        for uri in [
            "rtsp://192.0.2.5:554/live?user=admin&password=Adm1n@2024",
            "rtsp://192.0.2.5:554/user=admin_password=Adm1n@2024_channel=1_stream=0.sdp",
            "rtsp://admin:pw@192.0.2.5:554/live?password=Adm1n@2024"
        ] {
            XCTAssertFalse(splits(uri), uri)
        }
    }

    func testAURIWithoutAnAmbiguousAtSignIsNotSplit() {
        for uri in ["rtsp://admin:pw@192.0.2.5/s", "rtsp://192.0.2.5/s", "rtsp://192.0.2.5/live?password=x"] {
            XCTAssertFalse(splits(uri), uri)
        }
    }

    func testStrippingAReportedURI() {
        let cases = [
            "rtsp://192.0.2.5:554/live?user=admin&password=Adm1n@2024":
                "rtsp://192.0.2.5:554/live?user=admin&password=Adm1n@2024",
            "rtsp://192.0.2.5:554/user=admin_password=Adm1n@2024_channel=1":
                "rtsp://192.0.2.5:554/user=admin_password=Adm1n@2024_channel=1",
            "rtsp://admin:pw@192.0.2.5:554/live?password=Adm1n@2024": "rtsp://192.0.2.5:554/live?password=Adm1n@2024",
            "rtsp://admin:1234/5@192.0.2.5/s": "rtsp://192.0.2.5/s",
            "rtsp://user:p#ss@192.0.2.5/s": "rtsp://192.0.2.5/s",
            "rtsp://user:p#ss@192.0.2.9/s": "rtsp://192.0.2.9/s",
            "rtsp://user:1234#ab@192.0.2.9/s": "rtsp://192.0.2.9/s",
            "rtsp://admin:pw@192.0.2.5/s": "rtsp://192.0.2.5/s"
        ]
        for (uri, stripped) in cases {
            let saved = SourceCredentials.strippingUserInfo(fromReportedURI: uri, onvifHost: "192.0.2.5")
            XCTAssertEqual(saved, stripped, uri)
        }
    }

    /// A URI `URLComponents` can't read, not split because a `/` or `?` comes before its
    /// last `@` and the host after it is not the camera: a login in it can't be taken
    /// out, so it is not kept.
    func testAnUnreadableURIThatIsNotSplitIsNotKept() {
        for uri in ["rtsp://user:p?ss@192.0.2.9/s", "rtsp://192.0.2.5:554:1/live?password=p@ss word"] {
            XCTAssertNil(SourceCredentials.strippingUserInfo(fromReportedURI: uri, onvifHost: "192.0.2.5"), uri)
        }
    }

    // MARK: - Saving

    /// Adds an ONVIF camera at `host` that reported `reported`, and returns the stream
    /// URI it was saved with and the saved file.
    private func save(reported: String, host: String = "192.0.2.5") throws -> (uri: String?, file: String) {
        let fileURL = try XCTUnwrap(directory).appendingPathComponent("sources.json")
        try? FileManager.default.removeItem(at: fileURL)
        let manager = SourceManager(storage: SourceStorage(fileURL: fileURL), keychain: InMemoryCredentialStore())
        try manager.addSource(name: "Porch", sourceType: .onvif(ONVIFSourceInfo(
            host: host, port: 80, selectedProfileToken: "main", streamURI: reported
        )))
        guard case .onvif(let info) = try XCTUnwrap(manager.sources.first).sourceType else {
            XCTFail("expected ONVIF")
            return (nil, "")
        }
        return (info.streamURI, try String(contentsOf: fileURL, encoding: .utf8))
    }

    func testALoginInTheQueryIsSavedWithTheAddress() throws {
        let reported = "rtsp://192.0.2.5:554/live?user=admin&password=Adm1n@2024"
        XCTAssertEqual(try save(reported: reported).uri, reported)
    }

    func testALoginInTheUserInfoIsDroppedBeforeSaving() throws {
        let readable = try save(reported: "rtsp://admin:s3cret@192.0.2.5:554/live?password=Adm1n@2024")
        XCTAssertEqual(readable.uri, "rtsp://192.0.2.5:554/live?password=Adm1n@2024")
        XCTAssertFalse(readable.file.contains("s3cret"))

        let rawSlash = try save(reported: "rtsp://admin:12/34@192.0.2.5/main")
        XCTAssertEqual(rawSlash.uri, "rtsp://192.0.2.5/main")
        XCTAssertFalse(rawSlash.file.contains("12/34"))
    }

    /// The reported case: a camera saved by its name reports its IP address with a `#`
    /// in the password. It was saved without a fallback URI.
    func testAnUnreadableLoginIsTakenOutForACameraSavedByName() throws {
        let saved = try save(reported: "rtsp://admin:p#ss@192.168.1.20/s", host: "frontdoor.local")
        XCTAssertEqual(saved.uri, "rtsp://192.168.1.20/s")
        XCTAssertFalse(saved.file.contains("p#ss"))
        XCTAssertFalse(saved.file.contains("admin"))

        let misread = try save(reported: "rtsp://user:1234#ab@192.168.1.20/s", host: "frontdoor.local")
        XCTAssertEqual(misread.uri, "rtsp://192.168.1.20/s")
        XCTAssertFalse(misread.file.contains("1234#ab"))
    }

    func testAnUnreadableLoginThatMayBeAQueryIsNotSaved() throws {
        let unreadable = try save(reported: "rtsp://admin:s3c?ret@192.0.2.9:554/main")
        XCTAssertNil(unreadable.uri)
        XCTAssertFalse(unreadable.file.contains("s3c"))
    }

    /// Kept as reported, or not at all where `URLComponents` can't read it (that
    /// depends on the macOS version); never split into host `ss word`.
    func testALoginInAQueryWithASpaceIsNotSplitBeforeSaving() throws {
        let reported = "rtsp://192.168.1.20:554/live?password=p@ss word"
        let saved = try save(reported: reported, host: "frontdoor.local")
        XCTAssertTrue(saved.uri == nil || saved.uri == reported, saved.uri ?? "nil")
    }
}

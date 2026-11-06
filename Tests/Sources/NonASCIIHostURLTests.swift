@testable import LemurCam
import XCTest

/// IPCamKit writes a URL whose host is non-ASCII or percent-encoded out again through
/// `URLComponents`, for the `xn--` form of the host, and that encodes the `%` of the
/// escapes in a part that also holds a character it must encode. A URL with a login
/// was saved as `URLComponents(cameraURL:)` reads it once the login was taken out, so
/// IPCamKit sent it right, but one without a login was saved as typed:
/// `rtsp://café.local/live/a{%20b` was sent as `/live/a%7B%2520b`. Such a URL is now
/// saved as one with a login is; any other is still kept as typed. Keychain access goes
/// to an in-memory store.
@MainActor
internal final class NonASCIIHostURLTests: XCTestCase {
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

    private static let typed = "rtsp://café.local/live/a{%20b"
    private static let written = "rtsp://caf%C3%A9.local/live/a%7B%20b"
    private static let ordinary = [
        "rtsp://192.168.1.10/cam/realmonitor?channel=1&subtype=0",
        "rtsps://camera.local:322/Streaming/Channels/101?transportmode=unicast",
        // A non-ASCII host, but nothing `URLComponents` encodes: IPCamKit sends it right.
        "rtsp://café.local/live", "rtsp://café.local/caméra%20one",
        // An ASCII or IPv6 host: IPCamKit sends it as written.
        "rtsp://cam/a{%20b", "rtsp://[fe80::1%en0]/s|1%20"
    ]

    /// Written as the same URL with a login is once the login is taken out.
    func testAURLWithoutALoginIsWrittenSoIPCamKitDecodesItsEscapesOnce() {
        let cases = [
            Self.typed: Self.written,
            "rtsp://caf%C3%A9.local/live/a{%20b": Self.written,
            "rtsp://admin:pw@café.local/live/a{%20b": Self.written,
            "rtsp://café.local:8554/s?q={%26}#f": "rtsp://caf%C3%A9.local:8554/s?q=%7B%26%7D#f"
        ]
        for (url, expected) in cases {
            XCTAssertNil(RTSPURLInput.problem(with: url), url)
            XCTAssertEqual(SourceCredentials.extractingFromRTSPURL(url).url, expected, url)
            XCTAssertEqual(SourceCredentials.extractingFromRTSPURL(expected).url, expected, "kept once written")
        }
    }

    func testAnyOtherURLWithoutALoginIsKeptAsTyped() {
        for url in Self.ordinary {
            let extracted = SourceCredentials.extractingLoginFromRTSPURL(url)
            XCTAssertEqual(extracted.url, url)
            XCTAssertNil(extracted.login, url)
        }
    }

    /// A URL split at its last `@` (a `#` in the password) is left without a login
    /// too: a reported stream URI, or one an older version saved.
    func testWhatASplitLeavesIsWrittenSo() {
        let split = SourceCredentials.extractingLoginFromRTSPURL("rtsp://admin:p#ss@café.local/live/a{%20b")
        XCTAssertEqual(split.url, Self.written)
        XCTAssertEqual(split.login?.credentials, SourceCredentials(username: "admin", password: "p#ss"))
    }

    /// What is saved is what is connected to.
    func testAReportedURIWithoutALoginIsSavedAndConnectedToSo() {
        let target = StreamCoordinator.connectionTarget(
            forResolvedURI: Self.typed, reportedBy: "café.local", savedCredentials: nil
        )
        XCTAssertEqual(target.url, Self.written)
        XCTAssertNil(target.credentials)
        assertConnectsWhereSaved(Self.typed, reportedBy: "café.local")
    }

    func testAnAddedCameraIsSavedSo() throws {
        let fileURL = try XCTUnwrap(directory).appendingPathComponent("sources.json")
        let manager = SourceManager(storage: SourceStorage(fileURL: fileURL), keychain: InMemoryCredentialStore())

        for url in [Self.typed] + Self.ordinary {
            try manager.addSource(name: "Porch", sourceType: .rtsp(RTSPSourceInfo(url: url)))
        }

        XCTAssertEqual(manager.sources.map(\.sourceType), ([Self.written] + Self.ordinary).map {
            SourceType.rtsp(RTSPSourceInfo(url: $0))
        })
    }

    /// An older version saved such a URL as typed; loading writes it as the add form
    /// saves it now. The app can't tell it from one a camera's double-encoded path
    /// happened to match.
    func testASavedURLIsWrittenSoOnLoad() throws {
        let fileURL = try XCTUnwrap(directory).appendingPathComponent("sources.json")
        let sources = ([Self.typed] + Self.ordinary).map {
            CameraSource(name: "Porch", sourceType: .rtsp(RTSPSourceInfo(url: $0)))
        }
        SourceStorage(fileURL: fileURL).save(sources)
        let keychain = InMemoryCredentialStore()
        let manager = SourceManager(storage: SourceStorage(fileURL: fileURL), keychain: keychain)

        manager.load()

        XCTAssertEqual(manager.sources.map(\.sourceType), ([Self.written] + Self.ordinary).map {
            SourceType.rtsp(RTSPSourceInfo(url: $0))
        })
        XCTAssertTrue(keychain.writes.isEmpty)
    }
}

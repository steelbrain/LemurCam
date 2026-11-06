import IPCamKit
@testable import LemurCam
import XCTest

/// IPCamKit 0.4 wrote a URL whose host is non-ASCII or percent-encoded out again
/// through `URLComponents`, for the `xn--` form of the host, and that encoded the `%`
/// of the escapes in a part that also held a character it must encode:
/// `rtsp://café.local/live/a{%20b` was sent as `/live/a%7B%2520b`. The app saved such
/// a URL as `URLComponents(cameraURL:)` reads it (`rtsp://caf%C3%A9.local/live/a%7B%20b`)
/// so IPCamKit sent it right. IPCamKit 0.5 replaces only the host and sends the path
/// and query as written, so such a URL is kept as typed again, and one saved in the
/// written form is left as it is: it is sent as saved. Keychain access goes to an
/// in-memory store.
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
    /// How the app saved `typed` while it used IPCamKit 0.4.
    private static let written = "rtsp://caf%C3%A9.local/live/a%7B%20b"
    private static let typedURLs = [
        typed, written,
        "rtsp://caf%C3%A9.local/live/a{%20b", "rtsp://café.local:8554/s?q={%26}#f",
        "rtsp://192.168.1.10/cam/realmonitor?channel=1&subtype=0",
        "rtsps://camera.local:322/Streaming/Channels/101?transportmode=unicast",
        "rtsp://café.local/live", "rtsp://café.local/caméra%20one",
        "rtsp://cam/a{%20b", "rtsp://[fe80::1%en0]/s|1%20"
    ]
    private static let typedSourceTypes = typedURLs.map { SourceType.rtsp(RTSPSourceInfo(url: $0)) }

    func testAURLWithoutALoginIsKeptAsTyped() {
        for url in Self.typedURLs {
            XCTAssertNil(RTSPURLInput.problem(with: url), url)
            let extracted = SourceCredentials.extractingLoginFromRTSPURL(url)
            XCTAssertEqual(extracted.url, url)
            XCTAssertNil(extracted.login, url)
        }
    }

    /// A login is taken out as `URLComponents(cameraURL:)` reads the URL, which writes
    /// the rest as it reads it.
    func testAURLWithALoginIsWrittenWithoutIt() {
        let extracted = SourceCredentials.extractingFromRTSPURL("rtsp://admin:pw@café.local/live/a{%20b")
        XCTAssertEqual(extracted.url, Self.written)
        XCTAssertEqual(extracted.credentials, SourceCredentials(username: "admin", password: "pw"))
    }

    /// A URL split at its last `@` (a `#` in the password) keeps the rest as written:
    /// a reported stream URI, or one an older version saved.
    func testWhatASplitLeavesIsKeptAsWritten() {
        let split = SourceCredentials.extractingLoginFromRTSPURL("rtsp://admin:p#ss@café.local/live/a{%20b")
        XCTAssertEqual(split.url, Self.typed)
        XCTAssertEqual(split.login?.credentials, SourceCredentials(username: "admin", password: "p#ss"))
    }

    /// What is saved is what is connected to: the URI as reported.
    func testAReportedURIWithoutALoginIsSavedAndConnectedToAsReported() {
        let target = StreamCoordinator.connectionTarget(
            forResolvedURI: Self.typed, reportedBy: "café.local", savedCredentials: nil
        )
        XCTAssertEqual(target.url, Self.typed)
        XCTAssertNil(target.credentials)
        assertConnectsWhereSaved(Self.typed, reportedBy: "café.local")
    }

    func testAnAddedCameraIsSavedAsTyped() throws {
        let fileURL = try XCTUnwrap(directory).appendingPathComponent("sources.json")
        let manager = SourceManager(storage: SourceStorage(fileURL: fileURL), keychain: InMemoryCredentialStore())

        for url in Self.typedURLs {
            try manager.addSource(name: "Porch", sourceType: .rtsp(RTSPSourceInfo(url: url)))
        }

        XCTAssertEqual(manager.sources.map(\.sourceType), Self.typedSourceTypes)
    }

    /// A URL saved as typed by a version before the workaround, and one saved in the
    /// form it wrote, are both left as they are on load.
    func testASavedURLIsLeftAsItIsOnLoad() throws {
        let fileURL = try XCTUnwrap(directory).appendingPathComponent("sources.json")
        let sources = Self.typedURLs.map {
            CameraSource(name: "Porch", sourceType: .rtsp(RTSPSourceInfo(url: $0)))
        }
        SourceStorage(fileURL: fileURL).save(sources)
        let keychain = InMemoryCredentialStore()
        let manager = SourceManager(storage: SourceStorage(fileURL: fileURL), keychain: keychain)

        manager.load()

        XCTAssertEqual(manager.sources.map(\.sourceType), Self.typedSourceTypes)
        XCTAssertTrue(keychain.writes.isEmpty)
    }

    /// IPCamKit itself: a URL with a percent-encoded host takes the same path as one
    /// with a Unicode host (the host goes in its ASCII form), and its path and query
    /// reach the request line as written. A percent-encoded loopback address shows it
    /// without leaving this machine. IPCamKit 0.4 sent `/live/a%7B%2520b?q=x%7C%252Fy`.
    func testIPCamKitSendsThePathAndQueryOfAPercentEncodedHostAsWritten() async throws {
        let listener = try SilentLoopbackListener()
        defer { listener.close() }
        let url = "rtsp://127%2E0%2E0%2E1:\(listener.port)/live/a{%20b?q=x|%2Fy"
        let session = RTSPClientSession(url: url)

        let start = Task { try await session.start() }
        let requestLine = await Task.detached { listener.readRequestLine() }.value
        start.cancel()
        _ = await start.result

        XCTAssertEqual(requestLine, "OPTIONS rtsp://127.0.0.1:\(listener.port)/live/a{%20b?q=x|%2Fy RTSP/1.0")
    }
}

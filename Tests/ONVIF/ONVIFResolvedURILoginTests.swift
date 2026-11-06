@testable import LemurCam
import XCTest

/// Locks how a stream URI just fetched from an ONVIF camera is connected to when its
/// login has a raw `#` or `?` (`rtsp://viewer:p#ss@192.0.2.5:554/stream`).
/// IPCamKit refuses such a URI as ambiguous, so the camera could never stream. The
/// login is now taken out of the URI, and used only when the camera has no saved
/// credentials. That first covered only URIs `URLComponents` can't parse; one it
/// misreads as an address (`viewer:1234#ab@`) is split too. Either is split only
/// when what follows the last `@` is the camera's own host, so a login is never
/// taken from (or sent to a host made of) a query. Cameras are stubbed; nothing
/// goes on the network.
@MainActor
internal final class ONVIFResolvedURILoginTests: XCTestCase {
    nonisolated private static let reportedURI = "rtsp://viewer:p#ss@192.0.2.5:554/stream"
    private static let addressOnly = "rtsp://192.0.2.5:554/stream"
    private static let loginInURI = SourceCredentials(username: "viewer", password: "p#ss")
    private static let savedLogin = SourceCredentials(username: "saved-user", password: "saved-pw")

    private var fixture: CoordinatorHarness?
    private var stubHosts: [String] = []

    override func setUp() async throws {
        try await super.setUp()
        fixture = nil
        stubHosts = []
    }

    override func tearDown() async throws {
        stubHosts.forEach(ONVIFStubURLProtocol.unregister(host:))
        fixture?.cleanUp()
        fixture = nil
        try await super.tearDown()
    }

    // MARK: - What to connect to

    /// The camera's ONVIF service answered at this host.
    private static let onvifHost = "192.0.2.5"

    private static func target(
        _ uri: String, reportedBy host: String = onvifHost, saved: SourceCredentials? = nil
    ) -> (url: String, credentials: SourceCredentials?) {
        StreamCoordinator.connectionTarget(forResolvedURI: uri, reportedBy: host, savedCredentials: saved)
    }

    func testALoginURLComponentsCantReadIsTakenOutOfTheURI() {
        let target = Self.target(Self.reportedURI)

        XCTAssertEqual(target.url, Self.addressOnly)
        XCTAssertEqual(target.credentials, Self.loginInURI)
    }

    func testSavedCredentialsWinOverTheLoginInTheURI() {
        let target = Self.target(Self.reportedURI, saved: Self.savedLogin)

        XCTAssertEqual(target.url, Self.addressOnly)
        XCTAssertEqual(target.credentials, Self.savedLogin)
    }

    /// A URI `URLComponents` can't read is split only when what follows its last `@`
    /// is the camera, as one it reads is: that `@` may be in a query. With
    /// `?password=p@ss word` the split made `ss word`, the rest of the password, the
    /// host the login went to.
    func testALoginURLComponentsCantReadIsTakenOutOnlyWhenTheRestIsTheCamera() {
        let elsewhere = Self.target(Self.reportedURI, reportedBy: "porch-camera.local", saved: Self.savedLogin)
        XCTAssertEqual(elsewhere.url, Self.reportedURI)
        XCTAssertEqual(elsewhere.credentials, Self.savedLogin)

        // Whether `URLComponents` reads a space or a raw `%` depends on the macOS
        // version; the outcome must not. The last one it can't read on any.
        let queries = [
            "rtsp://192.0.2.5:554/stream?password=p@ss word",
            "rtsp://192.0.2.5/stream?user=viewer&password=p@ss word/x",
            "rtsp://192.0.2.5/stream?password=p@ss%zz",
            "rtsp://192.0.2.5:554:1/stream?password=p@ss word"
        ]
        XCTAssertNil(URLComponents(string: queries[3]))
        for uri in queries {
            let target = Self.target(uri, saved: Self.savedLogin)
            XCTAssertEqual(target.url, uri)
            XCTAssertEqual(target.credentials, Self.savedLogin)
            XCTAssertNil(Self.target(uri).credentials, "no login is taken from the query")
        }
    }

    /// The host after the last `@` of a URI `URLComponents` can't read: up to a port,
    /// path, query or fragment, or a bracketed IPv6 literal.
    func testTheRestOfAnUnreadableURIIsMatchedToTheCamera() {
        let cases: [(uri: String, reporter: String, url: String)] = [
            ("rtsp://viewer:p#ss@192.0.2.5/stream", "192.0.2.5", "rtsp://192.0.2.5/stream"),
            ("rtsp://viewer:p#ss@192.0.2.5", "192.0.2.5", "rtsp://192.0.2.5"),
            ("rtsp://viewer:p#ss@192.0.2.5?x=1", "192.0.2.5", "rtsp://192.0.2.5?x=1"),
            ("rtsp://viewer:p#ss@CAM.example:554/s", "cam.example", "rtsp://CAM.example:554/s"),
            ("rtsp://viewer:p#ss@[fe80::1]:554/s", "fe80:0::1", "rtsp://[fe80::1]:554/s")
        ]
        for (uri, reporter, url) in cases {
            XCTAssertNil(URLComponents(string: uri), "URLComponents can't read \(uri)")
            let target = Self.target(uri, reportedBy: reporter)
            XCTAssertEqual(target.url, url, uri)
            XCTAssertEqual(target.credentials, SourceCredentials(username: "viewer", password: "p#ss"), uri)
        }
        // No host to match: used as reported.
        for uri in ["rtsp://viewer:p#ss@[fe80::1:554/s", "rtsp://viewer:p#ss@:554/s"] {
            XCTAssertEqual(Self.target(uri, reportedBy: "fe80::1").url, uri)
        }
    }

    func testTheLeadingHostIsReadByHand() {
        XCTAssertEqual(StreamCoordinator.leadingHost(of: "rtsp://ss word"), "ss word")
        XCTAssertEqual(StreamCoordinator.leadingHost(of: "rtsp://host:554/s"), "host")
        XCTAssertEqual(StreamCoordinator.leadingHost(of: "rtsp://host#f"), "host")
        XCTAssertEqual(StreamCoordinator.leadingHost(of: "rtsp://[::1]:554"), "[::1]")
        XCTAssertNil(StreamCoordinator.leadingHost(of: "rtsp://[::1"))
        XCTAssertNil(StreamCoordinator.leadingHost(of: "rtsp:///s"))
        XCTAssertNil(StreamCoordinator.leadingHost(of: "host/s"))
    }

    /// Logins `URLComponents` reads as part of the address (host `viewer` and port
    /// 1234; an empty port; host `vi`), which IPCamKit refuses as ambiguous, so the
    /// camera never streamed. What follows the last `@` is the camera's own host.
    func testALoginURLComponentsMisreadsIsTakenOutWhenTheRestIsTheCamera() {
        let cases: [(uri: String, login: SourceCredentials)] = [
            ("rtsp://viewer:1234#ab@192.0.2.5:554/stream", .init(username: "viewer", password: "1234#ab")),
            ("rtsp://viewer:#ab@192.0.2.5:554/stream", .init(username: "viewer", password: "#ab")),
            ("rtsp://vi#ewer:pw@192.0.2.5:554/stream", .init(username: "vi#ewer", password: "pw"))
        ]
        for (uri, login) in cases {
            XCTAssertNotNil(URLComponents(string: uri), "URLComponents reads \(uri) as an address")

            let target = Self.target(uri)
            XCTAssertEqual(target.url, Self.addressOnly, uri)
            XCTAssertEqual(target.credentials, login, uri)
            XCTAssertEqual(Self.target(uri, saved: Self.savedLogin).credentials, Self.savedLogin, uri)
        }
    }

    /// An IP literal names the same host however it is written, and a host name in
    /// any case.
    func testTheRestIsMatchedToTheCameraByValue() {
        XCTAssertEqual(Self.target("rtsp://viewer:1234#ab@CAM.example/stream", reportedBy: "cam.example").url,
                       "rtsp://CAM.example/stream")
        XCTAssertEqual(Self.target("rtsp://viewer:1234#ab@[fe80::1]:554/stream", reportedBy: "fe80:0::1").url,
                       "rtsp://[fe80::1]:554/stream")
    }

    func testAURIThatURLComponentsCanReadIsUsedAsReported() {
        let uris = [
            Self.addressOnly,
            "rtsp://viewer:pw@192.0.2.5:554/stream",
            // Ambiguous to IPCamKit too, but the `@` may well belong to the query:
            // split there, the saved login would go to host `ss`.
            "rtsp://192.0.2.5:554/stream?user=viewer&password=p@ss",
            // Misread like the logins above, but what follows the `@` is not the
            // camera that reported it.
            "rtsp://viewer:1234#ab@192.0.2.99:554/stream"
        ]
        for uri in uris {
            let target = Self.target(uri, saved: Self.savedLogin)
            XCTAssertEqual(target.url, uri)
            XCTAssertEqual(target.credentials, Self.savedLogin)
        }
    }

    // MARK: - Through the coordinator

    func testACameraWithoutSavedCredentialsConnectsWithTheLoginFromTheURI() async throws {
        let host = "login-in-uri.test"
        let harness = try makeHarness(cameraAt: host, credentials: nil)

        harness.coordinator.previewStore.isPreviewEnabled = true
        let connected = await waitUntil(timeout: 5) { !harness.pipeline.connectedURLs.isEmpty }

        XCTAssertTrue(connected)
        XCTAssertEqual(harness.pipeline.connectedURLs, ["rtsp://\(host):554/stream"])
        XCTAssertEqual(harness.pipeline.connectedCredentials, [Self.loginInURI])
    }

    func testACameraWithSavedCredentialsConnectsWithThem() async throws {
        let host = "saved-login.test"
        let harness = try makeHarness(cameraAt: host, credentials: Self.savedLogin)

        harness.coordinator.previewStore.isPreviewEnabled = true
        let connected = await waitUntil(timeout: 5) { !harness.pipeline.connectedURLs.isEmpty }

        XCTAssertTrue(connected)
        XCTAssertEqual(harness.pipeline.connectedURLs, ["rtsp://\(host):554/stream"])
        XCTAssertEqual(harness.pipeline.connectedCredentials, [Self.savedLogin])
    }

    /// A login `URLComponents` can't read, in a URI for a host other than the camera
    /// that reported it, is left in the URI, and the saved credentials go with it.
    func testAnUnreadableLoginForAnotherHostIsConnectedToAsReported() async throws {
        let harness = try makeHarness(
            cameraAt: "reports-another-host.test", credentials: Self.savedLogin, reporting: Self.reportedURI
        )

        harness.coordinator.previewStore.isPreviewEnabled = true
        let connected = await waitUntil(timeout: 5) { !harness.pipeline.connectedURLs.isEmpty }

        XCTAssertTrue(connected)
        XCTAssertEqual(harness.pipeline.connectedURLs, [Self.reportedURI])
        XCTAssertEqual(harness.pipeline.connectedCredentials, [Self.savedLogin])
    }

    /// The stream URI comes from the saved address, so the resolve tells
    /// `connectionTarget` that host.
    func testAMisreadLoginFromTheSavedAddressIsTakenOut() async throws {
        let host = "misread-login.test"
        let harness = try makeHarness(
            cameraAt: host, credentials: nil, reporting: "rtsp://viewer:1234#ab@\(host):554/stream"
        )

        harness.coordinator.previewStore.isPreviewEnabled = true
        let connected = await waitUntil(timeout: 5) { !harness.pipeline.connectedURLs.isEmpty }

        XCTAssertTrue(connected)
        XCTAssertEqual(harness.pipeline.connectedURLs, ["rtsp://\(host):554/stream"])
        XCTAssertEqual(
            harness.pipeline.connectedCredentials, [SourceCredentials(username: "viewer", password: "1234#ab")]
        )
    }

    /// A coordinator whose ONVIF requests go to a stub camera at `host`, which
    /// reports `uri` (by default, the reported login at its own host), and an ONVIF
    /// camera saved there.
    private func makeHarness(
        cameraAt host: String, credentials: SourceCredentials?, reporting uri: String? = nil
    ) throws -> CoordinatorHarness {
        stubHosts.append(host)
        let reply = ONVIFResolveFixture.streamURIReply(uri ?? "rtsp://viewer:p#ss@\(host):554/stream")
        ONVIFStubURLProtocol.register(host: host) { _, _ in reply }
        let harness = CoordinatorHarness(onvifEnvironment: ONVIFResolveEnvironment(
            scan: { [] },
            makeClient: { info, credentials in
                ONVIFClient(
                    host: info.host, port: info.port, username: credentials?.username,
                    password: credentials?.password, useHTTPS: info.useHTTPS,
                    configuration: ONVIFStubURLProtocol.configuration()
                )
            }
        ))
        fixture = harness
        try harness.manager.addSource(
            name: "Porch",
            sourceType: .onvif(ONVIFSourceInfo(deviceUUID: nil, host: host, port: 80, selectedProfileToken: "main")),
            credentials: credentials
        )
        return harness
    }
}

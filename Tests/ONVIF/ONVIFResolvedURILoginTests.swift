@testable import LemurCam
import XCTest

/// Locks how a stream URI just fetched from an ONVIF camera is connected to when its
/// login has a raw `#` or `?` (`rtsp://viewer:p#ss@192.0.2.5:554/stream`).
/// IPCamKit refuses such a URI as ambiguous, so the camera could never stream. The
/// login is now taken out of the URI, and used only when the camera has no saved
/// credentials. That first covered only URIs `URLComponents` can't parse; one it
/// misreads as an address (`viewer:1234#ab@`) is split too when what follows the
/// last `@` is the camera's own host. Cameras are stubbed; nothing goes on the
/// network.
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

    /// A URI `URLComponents` can't read is split wherever it points, as before: the
    /// camera may report an address other than the one its ONVIF service answers at.
    func testALoginURLComponentsCantReadIsTakenOutWhateverTheHost() {
        let target = Self.target(Self.reportedURI, reportedBy: "porch-camera.local")

        XCTAssertEqual(target.url, Self.addressOnly)
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
        let harness = try makeHarness(cameraAt: "login-in-uri.test", credentials: nil)

        harness.coordinator.previewStore.isPreviewEnabled = true
        let connected = await waitUntil(timeout: 5) { !harness.pipeline.connectedURLs.isEmpty }

        XCTAssertTrue(connected)
        XCTAssertEqual(harness.pipeline.connectedURLs, [Self.addressOnly])
        XCTAssertEqual(harness.pipeline.connectedCredentials, [Self.loginInURI])
    }

    func testACameraWithSavedCredentialsConnectsWithThem() async throws {
        let harness = try makeHarness(cameraAt: "saved-login.test", credentials: Self.savedLogin)

        harness.coordinator.previewStore.isPreviewEnabled = true
        let connected = await waitUntil(timeout: 5) { !harness.pipeline.connectedURLs.isEmpty }

        XCTAssertTrue(connected)
        XCTAssertEqual(harness.pipeline.connectedURLs, [Self.addressOnly])
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
    /// reports `uri`, and an ONVIF camera saved there.
    private func makeHarness(
        cameraAt host: String, credentials: SourceCredentials?, reporting uri: String = reportedURI
    ) throws -> CoordinatorHarness {
        stubHosts.append(host)
        ONVIFStubURLProtocol.register(host: host) { _, _ in ONVIFResolveFixture.streamURIReply(uri) }
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

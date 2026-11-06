@testable import LemurCam
import XCTest

/// Locks how a stream URI just fetched from an ONVIF camera is connected to when its
/// login has a raw `#` or `?` (`rtsp://viewer:p#ss@192.0.2.5:554/stream`).
/// `URLComponents` can't parse such a URI, and IPCamKit refuses it as ambiguous, so
/// the camera could never stream. The login is now taken out of the URI, and used
/// only when the camera has no saved credentials. Cameras are stubbed; nothing goes
/// on the network.
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

    func testALoginURLComponentsCantReadIsTakenOutOfTheURI() {
        let target = StreamCoordinator.connectionTarget(forResolvedURI: Self.reportedURI, savedCredentials: nil)

        XCTAssertEqual(target.url, Self.addressOnly)
        XCTAssertEqual(target.credentials, Self.loginInURI)
    }

    func testSavedCredentialsWinOverTheLoginInTheURI() {
        let target = StreamCoordinator.connectionTarget(
            forResolvedURI: Self.reportedURI, savedCredentials: Self.savedLogin
        )

        XCTAssertEqual(target.url, Self.addressOnly)
        XCTAssertEqual(target.credentials, Self.savedLogin)
    }

    func testAURIThatURLComponentsCanReadIsUsedAsReported() {
        let uris = [
            Self.addressOnly,
            "rtsp://viewer:pw@192.0.2.5:554/stream",
            // Ambiguous to IPCamKit too, but it reads as an address: the `@` may well
            // belong to the query, so nothing is split off.
            "rtsp://192.0.2.5:554/stream?user=viewer&password=p@ss"
        ]
        for uri in uris {
            let target = StreamCoordinator.connectionTarget(forResolvedURI: uri, savedCredentials: Self.savedLogin)
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

    /// A coordinator whose ONVIF requests go to a stub camera at `host`, which
    /// reports `reportedURI`, and an ONVIF camera saved there.
    private func makeHarness(cameraAt host: String, credentials: SourceCredentials?) throws -> CoordinatorHarness {
        stubHosts.append(host)
        ONVIFStubURLProtocol.register(host: host) { _, _ in ONVIFResolveFixture.streamURIReply(Self.reportedURI) }
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

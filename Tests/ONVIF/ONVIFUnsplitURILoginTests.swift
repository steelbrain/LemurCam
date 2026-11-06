@testable import LemurCam
import XCTest

/// A stream URI an ONVIF camera reports that is not split at its last `@` was saved
/// without the login `URLComponents` reads in it, but connected to as reported. IPCamKit
/// checks that URL, not the credentials passed with it, so a login with a space
/// (`rtsp://admin:pa ss@192.0.2.5/s`), or an `@` in the query after a login
/// (`rtsp://admin:pw@192.0.2.5/s?a=b@c`), was refused on every connect while every
/// resolve worked. That login is now taken out for connecting too, and used only when
/// the camera has no saved credentials. Cameras are stubbed; nothing goes on the network.
@MainActor
internal final class ONVIFUnsplitURILoginTests: XCTestCase {
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

    func testALoginURLComponentsReadsIsTakenOutAsFromTheSavedCopy() {
        let cases: [(uri: String, url: String, login: SourceCredentials)] = [
            ("rtsp://viewer:pw@192.0.2.5:554/s", "rtsp://192.0.2.5:554/s", .init(username: "viewer", password: "pw")),
            ("rtsp://admin:pa ss@192.0.2.5/s", "rtsp://192.0.2.5/s", .init(username: "admin", password: "pa ss")),
            ("rtsp://admin:pw@192.0.2.5/s?a=b@c", "rtsp://192.0.2.5/s?a=b@c", .init(username: "admin", password: "pw"))
        ]
        for (uri, url, login) in cases {
            XCTAssertFalse(SourceCredentials.splitsAtLastAt(reportedURI: uri, onvifHost: "192.0.2.5"), uri)
            let target = StreamCoordinator.connectionTarget(
                forResolvedURI: uri, reportedBy: "192.0.2.5", savedCredentials: nil
            )
            XCTAssertEqual(target.url, url, uri)
            XCTAssertEqual(target.credentials, login, uri)
            let withSaved = StreamCoordinator.connectionTarget(
                forResolvedURI: uri, reportedBy: "192.0.2.5", savedCredentials: Self.savedLogin
            )
            XCTAssertEqual(withSaved.url, url, uri)
            XCTAssertEqual(withSaved.credentials, Self.savedLogin, uri)
            assertConnectsWhereSaved(uri)
        }
    }

    /// The reported case through the coordinator: the saved credentials go with the
    /// URL the camera saves.
    func testALoginWithASpaceIsTakenOutBeforeConnecting() async throws {
        let host = "login-with-space.test"
        stubHosts.append(host)
        let reply = ONVIFResolveFixture.streamURIReply("rtsp://viewer:pa ss@\(host):554/stream")
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
            credentials: Self.savedLogin
        )

        harness.coordinator.previewStore.isPreviewEnabled = true
        let connected = await waitUntil(timeout: 5) { !harness.pipeline.connectedURLs.isEmpty }

        XCTAssertTrue(connected)
        XCTAssertEqual(harness.pipeline.connectedURLs, ["rtsp://\(host):554/stream"])
        XCTAssertEqual(harness.pipeline.connectedCredentials, [Self.savedLogin])
    }
}

@testable import LemurCam
import XCTest

/// A stream URI an ONVIF camera reports that is not split at its last `@` was saved
/// without the login `URLComponents` reads in it, but connected to as reported. IPCamKit
/// checks that URL, not the credentials passed with it, so a login with a space
/// (`rtsp://admin:pa ss@192.0.2.5/s`), or an `@` in the query after a login
/// (`rtsp://admin:pw@192.0.2.5/s?a=b@c`), was refused on every connect while every
/// resolve worked. That login is now taken out for connecting too, and used only when
/// the camera has no saved credentials. With a port in the URI, IPCamKit refused any
/// `@` after the host (`rtsp://192.0.2.5:554/live?password=Adm1n@2024`), login or not,
/// and an ONVIF camera has no URL field where the user could write it `%40`. On the
/// camera's own host it is now written `%40` in what is saved and connected to.
/// Cameras are stubbed; nothing goes on the network.
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

    private static func target(
        _ uri: String, reportedBy camera: String
    ) -> (url: String, credentials: SourceCredentials?) {
        StreamCoordinator.connectionTarget(forResolvedURI: uri, reportedBy: camera, savedCredentials: nil)
    }

    /// The reported cases, in the query and in the path, and an `@` IPCamKit refuses
    /// for a `:` before it rather than a port. An IP literal or a name compares as
    /// the camera's by value.
    func testAnAtSignAfterTheCamerasHostIsWrittenAsAnEscape() {
        let cases: [(uri: String, camera: String, url: String)] = [
            ("rtsp://192.0.2.5:554/live?password=Adm1n@2024", "192.0.2.5",
             "rtsp://192.0.2.5:554/live?password=Adm1n%402024"),
            ("rtsp://viewer:pw@192.0.2.5:554/s?a=b@c", "192.0.2.5", "rtsp://192.0.2.5:554/s?a=b%40c"),
            ("rtsp://192.0.2.5:554/user=admin_password=Adm1n@2024_channel=1.sdp", "192.0.2.5",
             "rtsp://192.0.2.5:554/user=admin_password=Adm1n%402024_channel=1.sdp"),
            ("rtsp://192.0.2.5/s?a=b:c@d", "192.0.2.5", "rtsp://192.0.2.5/s?a=b:c%40d"),
            ("rtsp://192.0.2.5:554/s?a=b@c@d#e@f", "192.0.2.5", "rtsp://192.0.2.5:554/s?a=b%40c%40d#e%40f"),
            ("rtsp://CAM.example:554/s?p=a@b", "cam.example", "rtsp://CAM.example:554/s?p=a%40b"),
            ("rtsp://192.0.2.5:554/s?p=a@b", "::ffff:192.0.2.5", "rtsp://192.0.2.5:554/s?p=a%40b")
        ]
        for (uri, camera, url) in cases {
            XCTAssertTrue(SourceCredentials.hasAmbiguousUserInfo(uri), uri)
            XCTAssertFalse(SourceCredentials.splitsAtLastAt(reportedURI: uri, onvifHost: camera), uri)
            let target = Self.target(uri, reportedBy: camera)
            XCTAssertEqual(target.url, url, uri)
            XCTAssertFalse(SourceCredentials.hasAmbiguousUserInfo(target.url), uri)
            assertConnectsWhereSaved(uri, reportedBy: camera)
            XCTAssertEqual(SourceCredentials.strippingUserInfo(fromReportedURI: url, onvifHost: camera), url, "kept")
        }
        XCTAssertNil(Self.target(cases[0].uri, reportedBy: "192.0.2.5").credentials)
        XCTAssertEqual(
            Self.target(cases[1].uri, reportedBy: "192.0.2.5").credentials,
            SourceCredentials(username: "viewer", password: "pw")
        )
    }

    /// Only where the host is the camera that reported the URI: `URLComponents` reads
    /// the login in the first as host `viewer`, where the saved login would go. The
    /// second is still refused by IPCamKit: a camera saved by a name reporting its IP
    /// address can't be told from one reporting another device.
    func testAnAtSignAfterAnotherHostIsLeftAsReported() {
        let cases = [
            ("rtsp://viewer:12/34@192.0.2.99:554/stream", "192.0.2.5"),
            ("rtsp://192.168.1.20:554/live?password=Adm1n@2024", "frontdoor.local"),
            ("rtsp://192.0.2.9:554/live?password=Adm1n@2024", "192.0.2.5")
        ]
        for (uri, camera) in cases {
            let target = Self.target(uri, reportedBy: camera)
            XCTAssertEqual(target.url, uri)
            XCTAssertNil(target.credentials, uri)
            assertConnectsWhereSaved(uri, reportedBy: camera)
        }
    }

    /// The reported case through the coordinator: no login in the URI, so the saved
    /// credentials go with it.
    func testAnAtSignInTheQueryIsEscapedBeforeConnecting() async throws {
        let host = "at-sign-in-query.test"
        let harness = try makeHarness(cameraAt: host, reporting: "rtsp://\(host):554/live?password=Adm1n@2024")

        harness.coordinator.previewStore.isPreviewEnabled = true
        let connected = await waitUntil(timeout: 5) { !harness.pipeline.connectedURLs.isEmpty }

        XCTAssertTrue(connected)
        XCTAssertEqual(harness.pipeline.connectedURLs, ["rtsp://\(host):554/live?password=Adm1n%402024"])
        XCTAssertEqual(harness.pipeline.connectedCredentials, [Self.savedLogin])
    }

    /// The reported case through the coordinator: the saved credentials go with the
    /// URL the camera saves.
    func testALoginWithASpaceIsTakenOutBeforeConnecting() async throws {
        let host = "login-with-space.test"
        let harness = try makeHarness(cameraAt: host, reporting: "rtsp://viewer:pa ss@\(host):554/stream")

        harness.coordinator.previewStore.isPreviewEnabled = true
        let connected = await waitUntil(timeout: 5) { !harness.pipeline.connectedURLs.isEmpty }

        XCTAssertTrue(connected)
        XCTAssertEqual(harness.pipeline.connectedURLs, ["rtsp://\(host):554/stream"])
        XCTAssertEqual(harness.pipeline.connectedCredentials, [Self.savedLogin])
    }

    /// A coordinator whose ONVIF requests go to a stub camera at `host` that reports
    /// `uri`, and an ONVIF camera saved there with `savedLogin`.
    private func makeHarness(cameraAt host: String, reporting uri: String) throws -> CoordinatorHarness {
        stubHosts.append(host)
        let reply = ONVIFResolveFixture.streamURIReply(uri)
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
        return harness
    }
}

@testable import LemurCam
import XCTest

/// A stream URI an ONVIF camera reports that is not split at its last `@` was saved
/// without the login `URLComponents` reads in it, but connected to as reported. IPCamKit
/// checks that URL, not the credentials passed with it, so a login with a space
/// (`rtsp://admin:pa ss@192.0.2.5/s`), or an `@` in the query after a login
/// (`rtsp://admin:pw@192.0.2.5/s?a=b@c`), was refused on every connect while every
/// resolve worked. That login is now taken out for connecting too, and used only when
/// the camera has no saved credentials. IPCamKit refuses an `@` after a host name with
/// a port (`rtsp://frontdoor.local:554/live?password=Adm1n@2024`), or with a `:` before
/// it, login or not, and an ONVIF camera has no URL field where the user could write it
/// `%40`. After the camera's own host or an IP address it is written `%40` in what is
/// saved and connected to. IPCamKit 0.4 refused one after an IPv4 address with a port
/// too (`rtsp://192.0.2.5:554/live?password=Adm1n@2024`), which ONVIF cameras report;
/// 0.5 takes it, so it goes as reported.
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

    /// The reported cases on a camera saved by its name, in the query and in the path,
    /// and an `@` IPCamKit refuses for a `:` before it rather than a port. An IP literal
    /// or a name compares as the camera's by value.
    func testAnAtSignAfterTheCamerasHostIsWrittenAsAnEscape() {
        let cases: [(uri: String, camera: String, url: String)] = [
            ("rtsp://frontdoor.local:554/live?password=Adm1n@2024", "frontdoor.local",
             "rtsp://frontdoor.local:554/live?password=Adm1n%402024"),
            ("rtsp://viewer:pw@frontdoor.local:554/s?a=b@c", "frontdoor.local", "rtsp://frontdoor.local:554/s?a=b%40c"),
            ("rtsp://frontdoor.local:554/user=admin_password=Adm1n@2024_channel=1.sdp", "frontdoor.local",
             "rtsp://frontdoor.local:554/user=admin_password=Adm1n%402024_channel=1.sdp"),
            ("rtsp://192.0.2.5/s?a=b:c@d", "192.0.2.5", "rtsp://192.0.2.5/s?a=b:c%40d"),
            ("rtsp://192.0.2.5:554/s?a=b:c@d@e#f@g", "192.0.2.5", "rtsp://192.0.2.5:554/s?a=b:c%40d%40e#f%40g"),
            ("rtsp://CAM.example:554/s?p=a@b", "cam.example", "rtsp://CAM.example:554/s?p=a%40b"),
            ("rtsp://192.0.2.5/s?t=1:2&p=a@b", "::ffff:192.0.2.5", "rtsp://192.0.2.5/s?t=1:2&p=a%40b")
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
        XCTAssertNil(Self.target(cases[0].uri, reportedBy: "frontdoor.local").credentials)
        XCTAssertEqual(
            Self.target(cases[1].uri, reportedBy: "frontdoor.local").credentials,
            SourceCredentials(username: "viewer", password: "pw")
        )
    }

    /// IPCamKit takes an `@` after an IPv4 address with a port when no `:` comes before
    /// it, as ONVIF cameras report it, so it goes as reported: on the camera's address,
    /// on the IP address a camera saved by a name reports, and on a recorder's. A login
    /// in the userinfo is still taken out. A URI an earlier version saved with `%40`
    /// is kept as it is.
    func testAnAtSignAfterAnIPv4AddressWithAPortGoesAsReported() {
        let cases: [(uri: String, camera: String, url: String)] = [
            ("rtsp://192.0.2.5:554/live?password=Adm1n@2024", "192.0.2.5", "rtsp://192.0.2.5:554/live?password=Adm1n@2024"),
            ("rtsp://192.0.2.5:554/user=admin_password=Adm1n@2024_channel=1.sdp", "192.0.2.5",
             "rtsp://192.0.2.5:554/user=admin_password=Adm1n@2024_channel=1.sdp"),
            ("rtsp://192.0.2.5:554/s?a=b@c@d#e@f", "192.0.2.5", "rtsp://192.0.2.5:554/s?a=b@c@d#e@f"),
            ("rtsp://192.168.1.20:554/live?password=Adm1n@2024", "frontdoor.local",
             "rtsp://192.168.1.20:554/live?password=Adm1n@2024"),
            ("rtsp://192.0.2.9:554/stream?user=viewer&password=p@ss", "192.0.2.5",
             "rtsp://192.0.2.9:554/stream?user=viewer&password=p@ss"),
            ("rtsp://viewer:pw@192.0.2.5:554/s?a=b@c", "192.0.2.5", "rtsp://192.0.2.5:554/s?a=b@c"),
            ("rtsp://192.0.2.5:554/live?password=Adm1n%402024", "192.0.2.5", "rtsp://192.0.2.5:554/live?password=Adm1n%402024")
        ]
        for (uri, camera, url) in cases {
            XCTAssertFalse(SourceCredentials.splitsAtLastAt(reportedURI: uri, onvifHost: camera), uri)
            let target = Self.target(uri, reportedBy: camera)
            XCTAssertEqual(target.url, url, uri)
            XCTAssertFalse(SourceCredentials.hasAmbiguousUserInfo(target.url), uri)
            assertConnectsWhereSaved(uri, reportedBy: camera)
        }
        XCTAssertNil(Self.target(cases[0].uri, reportedBy: "192.0.2.5").credentials)
        XCTAssertEqual(
            Self.target(cases[5].uri, reportedBy: "192.0.2.5").credentials,
            SourceCredentials(username: "viewer", password: "pw")
        )
    }

    /// Not where `URLComponents` reads the host from a login (`viewer`, where the saved
    /// login would go), or from what can't be told from one: a host name other than the
    /// camera's.
    func testAnAtSignAfterAHostThatMayBeALoginIsLeftAsReported() {
        let cases = [
            ("rtsp://viewer:12/34@192.0.2.99:554/stream", "192.0.2.5"),
            ("rtsp://nvr.local:554/live?password=Adm1n@2024", "192.0.2.5")
        ]
        for (uri, camera) in cases {
            let target = Self.target(uri, reportedBy: camera)
            XCTAssertEqual(target.url, uri)
            XCTAssertNil(target.credentials, uri)
            assertConnectsWhereSaved(uri, reportedBy: camera)
        }
    }

    /// A camera saved by a name reports its IP address, and a recorder serving the
    /// stream has one too. With a `:` before the `@`, IPCamKit refuses all of them on
    /// every connect. Split at the last `@`, the login would go to host `2024` or `ss`.
    func testAnAtSignAfterAnIPAddressIsWrittenAsAnEscape() {
        let cases = [
            ("rtsp://192.168.1.20:554/live?t=12:00&password=Adm1n@2024", "frontdoor.local"),
            ("rtsp://192.0.2.9/live?t=12:00&password=Adm1n@2024", "192.0.2.5"),
            ("rtsp://192.0.2.9:554/stream?user=viewer:x&password=p@ss", "192.0.2.5")
        ]
        for (uri, camera) in cases {
            let target = Self.target(uri, reportedBy: camera)
            XCTAssertEqual(target.url, uri.replacingOccurrences(of: "@", with: "%40"), uri)
            XCTAssertFalse(SourceCredentials.hasAmbiguousUserInfo(target.url), uri)
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

    /// The ONVIF form of the reported case through the coordinator: an IPv4 address
    /// with a port, connected to as reported, with the saved credentials.
    func testAnAtSignInTheQueryAfterAnIPv4AddressWithAPortIsConnectedToAsReported() async throws {
        let reported = "rtsp://192.0.2.5:554/live?password=Adm1n@2024"
        let harness = try makeHarness(cameraAt: "at-sign-after-ipv4.test", reporting: reported)

        harness.coordinator.previewStore.isPreviewEnabled = true
        let connected = await waitUntil(timeout: 5) { !harness.pipeline.connectedURLs.isEmpty }

        XCTAssertTrue(connected)
        XCTAssertEqual(harness.pipeline.connectedURLs, [reported])
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
                    policy: .stubCamera, configuration: ONVIFStubURLProtocol.configuration()
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

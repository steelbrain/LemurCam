@testable import LemurCam
import XCTest

/// Rediscovery saved whatever LAN address the scan found over the saved one, so a
/// camera entered as `cam.local`, a DDNS name or a port-forwarded public address
/// (or with HTTPS) was permanently rewritten to `192.168.x.x:80` over HTTP, which
/// stops working away from home. A move is now saved only for a camera saved by its
/// LAN IP address, never replaces HTTPS with HTTP, and otherwise serves this
/// connection only. Cameras and scans are stubbed; nothing goes on the network.
@MainActor
internal final class ONVIFAddressPersistenceTests: XCTestCase {
    private var fixture: ONVIFResolveFixture?

    override func setUp() async throws {
        try await super.setUp()
        fixture = ONVIFResolveFixture()
    }

    override func tearDown() async throws {
        fixture?.cleanUp()
        fixture = nil
        try await super.tearDown()
    }

    // MARK: - Decisions

    func testOnlyLANAddressesCountAsLAN() {
        let lan = [
            "10.1.2.3", "172.16.0.9", "172.31.255.1", "192.168.1.20", "169.254.3.4",
            "fe80::1", "[fe80::1%en0]", "fd12:3456::1", "::ffff:192.168.1.20"
        ]
        for host in lan {
            XCTAssertTrue(ONVIFRediscovery.isLANAddress(host), host)
        }
        // Loopback is a tunnel or port forward to the camera, not the camera's LAN address.
        let other = [
            "cam.local", "porch", "cam.example.com", "203.0.113.5", "8.8.4.4", "172.32.0.1", "100.64.1.2",
            "2001:db8::1", "", "127.0.0.1", "127.8.9.10", "::1", "[::1]", "::ffff:127.0.0.1", "localhost"
        ]
        for host in other {
            XCTAssertFalse(ONVIFRediscovery.isLANAddress(host), host)
        }
    }

    func testShouldSaveOnlyMovesOfLANAddressesThatKeepHTTPS() {
        let saved = ONVIFSourceInfo(host: "192.168.1.20", port: 80)
        var moved = saved
        moved.host = "192.168.1.31"
        XCTAssertTrue(ONVIFRediscovery.shouldSave(moved, replacing: saved))

        for host in ["cam.local", "cam.example.com", "203.0.113.5"] {
            var named = saved
            named.host = host
            XCTAssertFalse(ONVIFRediscovery.shouldSave(moved, replacing: named), host)
        }

        let secure = ONVIFSourceInfo(host: "192.168.1.20", port: 443, useHTTPS: true)
        XCTAssertFalse(ONVIFRediscovery.shouldSave(moved, replacing: secure), "HTTPS must not become HTTP")
        var movedSecure = moved
        movedSecure.useHTTPS = true
        XCTAssertTrue(ONVIFRediscovery.shouldSave(movedSecure, replacing: secure))
    }

    /// A camera saved with HTTPS keeps HTTPS and its port at the address found, even
    /// when the scan reports its plain HTTP service; at its saved address that is no
    /// move at all.
    func testHTTPSCameraIsNeverMovedToHTTP() {
        let saved = ONVIFSourceInfo(
            deviceUUID: ONVIFResolveFixture.deviceUUID, host: "192.168.1.20", port: 8443, useHTTPS: true
        )
        var expected = saved
        expected.host = "192.168.1.31"
        XCTAssertEqual(ONVIFRediscovery.outcome(for: saved, among: [ONVIFResolveFixture.device(host: "192.168.1.31")]),
                       .moved(expected))
        XCTAssertEqual(ONVIFRediscovery.outcome(for: saved, among: [ONVIFResolveFixture.device(host: "192.168.1.20")]),
                       .unchanged)
    }

    // MARK: - Resolve flow

    /// A host name the user entered is kept; the LAN address the scan found serves
    /// this connection only.
    func testHostNameIsKeptAndTheFoundAddressUsedOnce() async throws {
        try await assertFoundAddressIsUsedOnce(savedHost: "porch-cam.local")
    }

    func testPublicAddressIsKeptAndTheFoundAddressUsedOnce() async throws {
        try await assertFoundAddressIsUsedOnce(savedHost: "203.0.113.5")
    }

    /// A camera reached through an SSH tunnel or a port forward on this Mac was
    /// permanently rewritten to the LAN address a scan found.
    func testLoopbackAddressIsKeptAndTheFoundAddressUsedOnce() async throws {
        try await assertFoundAddressIsUsedOnce(savedHost: "127.0.0.1")
    }

    private func assertFoundAddressIsUsedOnce(savedHost: String) async throws {
        let harness = try XCTUnwrap(fixture)
        harness.stub(host: "192.168.77.41", ONVIFResolveFixture.streamURIReply("rtsp://192.168.77.41/main"))
        let source = try harness.addCamera(host: savedHost, port: 8080)
        let fileBefore = try harness.savedFile()

        let result = try await StreamCoordinator.attemptONVIFResolve(
            params: harness.params(for: source, scanResult: [ONVIFResolveFixture.device(host: "192.168.77.41")])
        )

        XCTAssertEqual(try result.get().uri, "rtsp://192.168.77.41/main")
        XCTAssertEqual(harness.manager.sources.first, source)
        XCTAssertEqual(try harness.savedFile(), fileBefore, "the entered address must not be rewritten")
    }

    /// A moved HTTPS camera is asked over HTTPS at its new address, and that address
    /// is saved with HTTPS and the saved port.
    func testMovedHTTPSCameraIsQueriedAndSavedOverHTTPS() async throws {
        let harness = try XCTUnwrap(fixture)
        let schemes = CapturedBodies()
        ONVIFStubURLProtocol.register(host: "192.168.77.51") { request, _ in
            schemes.append(Data((request.url?.scheme ?? "").utf8))
            return ONVIFResolveFixture.streamURIReply("rtsp://192.168.77.51/main")
        }
        defer { ONVIFStubURLProtocol.unregister(host: "192.168.77.51") }
        let source = try harness.addCamera(host: "192.168.77.50", port: 8443, useHTTPS: true)

        let result = try await StreamCoordinator.attemptONVIFResolve(
            params: harness.params(for: source, scanResult: [ONVIFResolveFixture.device(host: "192.168.77.51")])
        )

        XCTAssertEqual(try result.get().uri, "rtsp://192.168.77.51/main")
        XCTAssertFalse(schemes.all.isEmpty)
        XCTAssertTrue(schemes.all.allSatisfy { $0 == Data("https".utf8) }, "no request may go over plain HTTP")
        let saved = try XCTUnwrap(harness.savedInfo(source))
        XCTAssertEqual(saved.host, "192.168.77.51")
        XCTAssertEqual(saved.port, 8443)
        XCTAssertTrue(saved.useHTTPS)
    }
}

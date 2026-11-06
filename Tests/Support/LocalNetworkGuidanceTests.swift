@testable import LemurCam
import XCTest

/// Pins the Local Network hint heuristic: it must fire only for LAN hosts whose
/// connection failed without reaching the host, so a merely-offline public camera, or
/// a LAN camera that answered with an error, never gets misattributed to a Local
/// Network permission problem. A failed connection goes straight on to
/// `.reconnecting` (the failure stays), so gating on `.error` alone meant the hint
/// never showed. Loopback is not gated by Local Network privacy; IPv6 LAN addresses
/// are.
internal final class LocalNetworkGuidanceTests: XCTestCase {

    // MARK: - LAN host classification

    func testPrivateRangesAreLAN() {
        let hosts = [
            "192.168.1.50", "10.0.0.4", "172.16.5.5", "172.31.255.255", "169.254.1.1",
            "camera.local", "Camera.Local.", "camera.home.arpa",
            "fd00::1", "fd12:3456:789a::5", "fc00::5", "fe80::1", "FE80::ABCD", "fe80::1%en0", "[fe80::1]",
            "febf::1", "::ffff:192.168.1.5"
        ]
        for host in hosts {
            XCTAssertTrue(LocalNetworkGuidance.isLANHost(host), "\(host) should be LAN")
        }
    }

    func testPublicAndAmbiguousHostsAreNotLAN() {
        let hosts = [
            "8.8.8.8", "172.32.0.1", "172.15.0.1", "203.0.113.7",
            "example.com", "camera.example.com", "local.example.com", "home.arpa.example.com",
            "127.0.0.1", "127.1.2.3", "localhost", "::1", "[::1]",
            "2001:db8::1", "fec0::1", "fe00::1", "::ffff:8.8.8.8", "fd00::zz", "fd00:::1"
        ]
        for host in hosts {
            XCTAssertFalse(LocalNetworkGuidance.isLANHost(host), "\(host) should not be LAN")
        }
    }

    // MARK: - Show/hide gate

    private func blocked(_ host: String?, _ status: ConnectionStatus, unreachable: Bool = true) -> Bool {
        LocalNetworkGuidance.isLikelyBlocked(host: host, status: status, hostUnreachable: unreachable)
    }

    func testHintShowsForAFailedLANHostWhileItWaitsToReconnect() {
        XCTAssertTrue(blocked("192.168.1.2", .reconnecting), "the status a failed connection is left in")
        XCTAssertTrue(blocked("192.168.1.2", .error))
    }

    func testHintNeedsAFailureThatDidNotReachTheHost() {
        // Reconnecting after the camera simply disconnected is not a failure, and a
        // camera that answered with an error was reached.
        XCTAssertFalse(blocked("192.168.1.2", .reconnecting, unreachable: false))
        XCTAssertFalse(blocked("192.168.1.2", .error, unreachable: false))
        XCTAssertTrue(blocked("fd00::2", .reconnecting))
    }

    func testHintOnlyShowsForAFailedLANHost() {
        // Not failed → no hint, even on a LAN host.
        for status: ConnectionStatus in [.pending, .connecting, .connected, .disconnected] {
            XCTAssertFalse(blocked("192.168.1.2", status), "\(status)")
        }
        // Failed but public host → not a Local Network problem.
        XCTAssertFalse(blocked("8.8.8.8", .error))
        XCTAssertFalse(blocked("8.8.8.8", .reconnecting))
        // No host → nothing to say.
        XCTAssertFalse(blocked(nil, .reconnecting))
    }

    // MARK: - Host extraction

    func testHostExtraction() throws {
        let rtsp = CameraSource(name: "Cam", sourceType: .rtsp(
            RTSPSourceInfo(url: "rtsp://192.168.1.20:554/stream")
        ))
        XCTAssertEqual(LocalNetworkGuidance.host(for: rtsp), "192.168.1.20")

        let onvif = CameraSource(name: "Cam2", sourceType: .onvif(
            ONVIFSourceInfo(host: "10.0.0.9", port: 80)
        ))
        XCTAssertEqual(LocalNetworkGuidance.host(for: onvif), "10.0.0.9")

        let ipv6 = CameraSource(name: "Cam3", sourceType: .rtsp(
            RTSPSourceInfo(url: "rtsp://[fd00::20]:554/stream")
        ))
        let host = try XCTUnwrap(LocalNetworkGuidance.host(for: ipv6))
        XCTAssertTrue(LocalNetworkGuidance.isLANHost(host), host)
    }
}

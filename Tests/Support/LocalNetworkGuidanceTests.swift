@testable import LemurCam
import XCTest

/// Pins the Local Network hint heuristic: it must fire only for LAN hosts whose
/// connection failed with an error, so a merely-offline public camera never gets
/// misattributed to a Local Network permission problem. A failed connection goes
/// straight on to `.reconnecting` (the error message stays), so gating on `.error`
/// alone meant the hint never showed.
internal final class LocalNetworkGuidanceTests: XCTestCase {

    // MARK: - LAN host classification

    func testPrivateRangesAreLAN() {
        let hosts = [
            "192.168.1.50", "10.0.0.4", "172.16.5.5", "172.31.255.255",
            "169.254.1.1", "127.0.0.1", "localhost", "camera.local"
        ]
        for host in hosts {
            XCTAssertTrue(LocalNetworkGuidance.isLANHost(host), "\(host) should be LAN")
        }
    }

    func testPublicAndAmbiguousHostsAreNotLAN() {
        let hosts = [
            "8.8.8.8", "172.32.0.1", "172.15.0.1", "203.0.113.7",
            "example.com", "camera.example.com"
        ]
        for host in hosts {
            XCTAssertFalse(LocalNetworkGuidance.isLANHost(host), "\(host) should not be LAN")
        }
    }

    // MARK: - Show/hide gate

    private func blocked(_ host: String?, _ status: ConnectionStatus, error: String? = "Connection refused") -> Bool {
        LocalNetworkGuidance.isLikelyBlocked(host: host, status: status, errorMessage: error)
    }

    func testHintShowsForAFailedLANHostWhileItWaitsToReconnect() {
        XCTAssertTrue(blocked("192.168.1.2", .reconnecting), "the status a failed connection is left in")
        XCTAssertTrue(blocked("192.168.1.2", .error))
    }

    func testHintNeedsAnErrorMessage() {
        // Reconnecting after the camera simply disconnected is not a failure.
        XCTAssertFalse(blocked("192.168.1.2", .reconnecting, error: nil))
        XCTAssertFalse(blocked("192.168.1.2", .error, error: nil))
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

    func testHostExtraction() {
        let rtsp = CameraSource(name: "Cam", sourceType: .rtsp(
            RTSPSourceInfo(url: "rtsp://192.168.1.20:554/stream")
        ))
        XCTAssertEqual(LocalNetworkGuidance.host(for: rtsp), "192.168.1.20")

        let onvif = CameraSource(name: "Cam2", sourceType: .onvif(
            ONVIFSourceInfo(host: "10.0.0.9", port: 80)
        ))
        XCTAssertEqual(LocalNetworkGuidance.host(for: onvif), "10.0.0.9")
    }
}

@testable import LemurCam
import XCTest

/// Pins the Local Network hint heuristic: it must fire only for LAN hosts in an
/// errored state, so a merely-offline public camera never gets misattributed to a
/// Local Network permission problem.
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

    func testHintOnlyShowsForErroredLANHost() {
        XCTAssertTrue(LocalNetworkGuidance.isLikelyBlocked(host: "192.168.1.2", status: .error))
        // Not errored → no hint, even on a LAN host.
        XCTAssertFalse(LocalNetworkGuidance.isLikelyBlocked(host: "192.168.1.2", status: .connecting))
        XCTAssertFalse(LocalNetworkGuidance.isLikelyBlocked(host: "192.168.1.2", status: .connected))
        // Errored but public host → not a Local Network problem.
        XCTAssertFalse(LocalNetworkGuidance.isLikelyBlocked(host: "8.8.8.8", status: .error))
        // No host → nothing to say.
        XCTAssertFalse(LocalNetworkGuidance.isLikelyBlocked(host: nil, status: .error))
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

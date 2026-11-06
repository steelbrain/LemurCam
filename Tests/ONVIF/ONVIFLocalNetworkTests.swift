@testable import LemurCam
import XCTest

/// App Transport Security blocked plain HTTP to a camera outside the local network
/// with no way to allow it. The app's ATS exception now lets every request through,
/// so `ONVIFClient` draws the same line itself and crosses it only for a camera whose
/// checkbox allows it. Cameras are stubbed; nothing goes on the network.
internal final class ONVIFLocalNetworkTests: XCTestCase {
    // MARK: - Where the line is

    /// What ATS allowed without any keys, as measured, and the ranges decided here:
    /// IPv4 link-local and IPv6 unique local addresses.
    func testAddressesATSAllowedCountAsLocal() {
        let local = [
            "10.0.0.9", "172.16.0.1", "172.31.255.254", "192.168.1.20", "::ffff:192.168.1.5",
            "127.0.0.1", "127.8.9.10", "::1", "[::1]",
            "fe80::1", "fe80::1%en0", "[fe80::1%25en0]", "169.254.10.1",
            "fd00::1", "fc12:3456::1",
            "camera", "CAMERA", "frontdoor.local", "Cam.LOCAL", "cam.local.", "localhost", "LocalHost"
        ]
        for host in local {
            XCTAssertTrue(ONVIFLocalNetwork.contains(host), host)
            XCTAssertFalse(ONVIFLocalNetwork.needsPlainHTTPAllowance(host: host, useHTTPS: false), host)
        }
    }

    /// What ATS blocked (-1022), as measured, and carrier-grade NAT, decided here.
    func testAddressesATSBlockedAreOutsideTheLocalNetwork() {
        let outside = [
            "8.8.4.4", "192.0.2.10", "203.0.113.5", "172.32.0.1", "11.0.0.1", "0.0.0.0",
            "100.64.0.1", "100.127.255.254",
            "2001:db8::1", "[2001:db8::1]", "2606:4700::1111",
            "camera.example.com", "cam.ddns.net", "camera.", "cam.local.example.com"
        ]
        for host in outside {
            XCTAssertFalse(ONVIFLocalNetwork.contains(host), host)
            XCTAssertTrue(ONVIFLocalNetwork.needsPlainHTTPAllowance(host: host, useHTTPS: false), host)
        }
        // A name without a dot is unqualified, whatever it says.
        XCTAssertTrue(ONVIFLocalNetwork.contains("local"))
    }

    func testHTTPSNeverNeedsTheAllowance() {
        for host in ["203.0.113.5", "camera.example.com", "2001:db8::1", "192.168.1.20"] {
            XCTAssertFalse(ONVIFLocalNetwork.needsPlainHTTPAllowance(host: host, useHTTPS: true), host)
        }
    }

    // MARK: - The client

    func testPlainHTTPOutsideTheLocalNetworkIsRefusedBeforeAnythingIsSent() async throws {
        let host = "onvif-plain-refused-\(UUID().uuidString).example.com"
        let requests = registerCountingStub(host)
        defer { ONVIFStubURLProtocol.unregister(host: host) }
        let client = ONVIFClient(
            host: host, port: 80, username: "viewer", password: "pw",
            configuration: ONVIFStubURLProtocol.configuration()
        )

        do {
            _ = try await client.getProfiles()
            XCTFail("expected plain HTTP to be refused")
        } catch ONVIFError.plainHTTPRefused(let refused) {
            XCTAssertEqual(refused, host)
        }
        XCTAssertTrue(requests.all.isEmpty, "nothing may be sent, the login least of all")
    }

    func testTheCamerasAllowanceOrHTTPSLetsTheRequestGo() async throws {
        let host = "onvif-plain-allowed-\(UUID().uuidString).example.com"
        let requests = registerCountingStub(host)
        defer { ONVIFStubURLProtocol.unregister(host: host) }
        let allowed = ONVIFClient(
            host: host, port: 80, username: nil, password: nil,
            policy: ONVIFConnectionPolicy(allowsPlainHTTPOutsideLocalNetwork: true),
            configuration: ONVIFStubURLProtocol.configuration()
        )
        let https = ONVIFClient(
            host: host, port: 443, username: nil, password: nil, useHTTPS: true,
            configuration: ONVIFStubURLProtocol.configuration()
        )

        _ = try await allowed.getStreamURI(profileToken: "main")
        let afterPlain = requests.all.count
        _ = try await https.getStreamURI(profileToken: "main")

        XCTAssertGreaterThan(afterPlain, 0)
        XCTAssertGreaterThan(requests.all.count, afterPlain)
    }

    func testTheRefusalNamesTheHostAndTheCheckbox() {
        let error = ONVIFError.plainHTTPRefused(host: "203.0.113.5")
        XCTAssertEqual(
            error.localizedDescription,
            "203.0.113.5 is outside your local network. Use HTTPS, or turn on Allow Unencrypted HTTP for this camera."
        )
        XCTAssertTrue(error.needsUserDecision)
        XCTAssertFalse(error.isTransportFailure)
        XCTAssertFalse(StreamCoordinator.mayFallBackToStoredURI(after: error))
        XCTAssertFalse(ONVIFRediscovery.shouldRediscover(after: error, at: ONVIFSourceInfo(host: "203.0.113.5")))
    }

    // MARK: - The form

    /// The allowance is saved only for an address that needs it, so one left ticked
    /// before the address changed doesn't apply to a later address.
    func testTheFormSavesTheAllowanceOnlyWhereItIsNeeded() {
        typealias Address = SourceFormONVIFAddressEdits.Address
        var details = SourceFormONVIFDetails()
        details.allowsPlainHTTPOutsideLocalNetwork = true

        let outside = details.sourceInfo(at: Address(host: "203.0.113.5", port: 80, useHTTPS: false))
        let local = details.sourceInfo(at: Address(host: "192.168.1.20", port: 80, useHTTPS: false))
        let https = details.sourceInfo(at: Address(host: "203.0.113.5", port: 443, useHTTPS: true))

        XCTAssertTrue(outside.allowsPlainHTTPOutsideLocalNetwork)
        XCTAssertFalse(local.allowsPlainHTTPOutsideLocalNetwork)
        XCTAssertFalse(https.allowsPlainHTTPOutsideLocalNetwork)
    }

    /// Connect again to the same address keeps what the user decided for it; a URL
    /// edit, or Connect to another address, doesn't.
    func testConnectAgainToTheSameAddressKeepsTheAllowance() {
        var details = SourceFormONVIFDetails()
        details.allowsPlainHTTPOutsideLocalNetwork = true
        details.trust(TestCertificate.otherFingerprint)

        var same = details
        same.clear(keepingAddressDecisions: true)
        var other = details
        other.clear()

        XCTAssertTrue(same.allowsPlainHTTPOutsideLocalNetwork)
        XCTAssertEqual(same.pinnedCertificate, TestCertificate.otherFingerprint)
        XCTAssertFalse(other.allowsPlainHTTPOutsideLocalNetwork)
        XCTAssertNil(other.pinnedCertificate)
    }

    // MARK: - Helpers

    /// Answers every request to `host` with a stream URI and records it.
    private func registerCountingStub(_ host: String) -> CapturedBodies {
        let requests = CapturedBodies()
        let reply = ONVIFResolveFixture.streamURIReply("rtsp://\(host):554/main")
        ONVIFStubURLProtocol.register(host: host) { _, body in
            requests.append(body)
            return reply
        }
        return requests
    }
}

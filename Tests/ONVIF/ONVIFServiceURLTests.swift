@testable import LemurCam
import XCTest

/// The device service URL was built with the ONVIF host as typed, so an IPv6 address
/// (`fe80::1`, `fe80::1%en0`) made `http://fe80::1:80/onvif/device_service`, which is
/// no URL: Fetch Profiles failed with "Invalid ONVIF device URL" every time, and the
/// camera could not be saved. The address now goes in brackets, with the `%` before its
/// zone written `%25`. Requests go to `ONVIFStubURLProtocol`; nothing goes on the network.
internal final class ONVIFServiceURLTests: XCTestCase {
    private func deviceServiceURL(_ host: String, port: Int = 80, useHTTPS: Bool = false) -> String? {
        ONVIFClient.serviceURL(host: host, port: port, useHTTPS: useHTTPS, path: ONVIFClient.deviceServicePath)?
            .absoluteString
    }

    func testAnIPv6AddressIsBracketedWithItsZoneEncoded() {
        XCTAssertNil(URL(string: "http://fe80::1:80/onvif/device_service"), "the URL as it was built")
        XCTAssertEqual(deviceServiceURL("fe80::1"), "http://[fe80::1]:80/onvif/device_service")
        XCTAssertEqual(deviceServiceURL("[fd00::5]"), "http://[fd00::5]:80/onvif/device_service")
        for host in ["fe80::1%en0", "[fe80::1%en0]", "fe80::1%25en0", "[fe80::1%25en0]"] {
            XCTAssertEqual(deviceServiceURL(host), "http://[fe80::1%25en0]:80/onvif/device_service", host)
        }
    }

    func testOtherHostsAreKept() {
        XCTAssertEqual(deviceServiceURL("192.168.1.64", port: 8080), "http://192.168.1.64:8080/onvif/device_service")
        XCTAssertEqual(
            deviceServiceURL("cam.local", port: 443, useHTTPS: true), "https://cam.local:443/onvif/device_service"
        )
        XCTAssertNil(deviceServiceURL("192.168.1.64:8080"), "the Host field refuses a port after the address")
    }

    /// The client sends its requests there. No stub camera answers, so the request
    /// fails as one to an unreachable camera does, not as an invalid URL.
    func testTheClientSendsToAnIPv6Address() async {
        let client = ONVIFClient(
            host: "fe80::1%en0", port: 80, username: nil, password: nil,
            configuration: ONVIFStubURLProtocol.configuration()
        )
        do {
            _ = try await client.getDeviceInformation()
            XCTFail("no camera answers")
        } catch ONVIFError.networkError(_, let code) {
            XCTAssertEqual(code, .cannotConnectToHost)
        } catch {
            XCTFail("expected a network error, got \(error)")
        }
    }

    /// A stored stream URI that follows the camera to a new address takes the address
    /// written the same way (`SourceCredentials.storedStreamURI`); a zone made it nil.
    func testAMovedStreamURITakesAnIPv6AddressWithItsZone() {
        XCTAssertEqual(
            SourceCredentials.storedStreamURI("rtsp://192.168.1.20/s", movedFrom: "192.168.1.20", to: "fe80::1%en0"),
            "rtsp://[fe80::1%25en0]/s"
        )
    }
}

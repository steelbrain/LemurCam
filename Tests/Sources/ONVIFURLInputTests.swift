@testable import LemurCam
import XCTest

/// The add form took the host of an ONVIF URL percent-decoded and never checked it:
/// `http://admin%3Asecret%40192.168.1.64/onvif/device_service` made the host
/// `admin:secret@192.168.1.64`, and the login was saved in the cameras file and shown
/// in the camera list. The host now has to pass the Host field's check
/// (`ONVIFHostInput`), and the URL is read as every camera URL is.
internal final class ONVIFURLInputTests: XCTestCase {
    private typealias Address = ONVIFURLInput.Address

    private func refusal(_ message: String) -> Result<Address, ONVIFURLInput.Problem> {
        .failure(ONVIFURLInput.Problem(message: message))
    }

    func testAHostTheHostFieldRefusesIsRefused() {
        let login = "http://admin%3Asecret%40192.168.1.64/onvif/device_service"
        XCTAssertEqual(URLComponents(string: login)?.host, "admin:secret@192.168.1.64", "the host as it was taken")
        XCTAssertEqual(ONVIFURLInput.address(in: login), refusal(ONVIFHostInput.loginMessage))
        XCTAssertEqual(
            ONVIFURLInput.address(in: "http://cam%2Fonvif/x"), refusal(ONVIFHostInput.notAnAddressMessage)
        )
    }

    func testTheAddressIsTakenFromTheURL() {
        XCTAssertEqual(
            ONVIFURLInput.address(in: "http://192.168.1.64/onvif/device_service"),
            .success(Address(host: "192.168.1.64", port: 80, useHTTPS: false))
        )
        XCTAssertEqual(
            ONVIFURLInput.address(in: "HTTPS://cam.local:8443/onvif/device_service"),
            .success(Address(host: "cam.local", port: 8443, useHTTPS: true))
        )
        XCTAssertEqual(
            ONVIFURLInput.address(in: "https://cam.local/onvif/device_service"),
            .success(Address(host: "cam.local", port: 443, useHTTPS: true))
        )
        XCTAssertEqual(
            ONVIFURLInput.address(in: "http://admin:pä|ss%40@192.168.1.64:8080/onvif/device_service"),
            .success(Address(host: "192.168.1.64", port: 8080, useHTTPS: false)),
            "a login in the userinfo is not part of the host"
        )
    }

    func testAnIPv6HostMakesADeviceServiceURL() throws {
        let address = try ONVIFURLInput.address(in: "http://[fe80::1%25en0]:8080/onvif/device_service").get()
        let url = ONVIFClient.serviceURL(
            host: address.host, port: address.port, useHTTPS: address.useHTTPS, path: ONVIFClient.deviceServicePath
        )
        XCTAssertEqual(url?.absoluteString, "http://[fe80::1%25en0]:8080/onvif/device_service")
    }

    func testAURLWithoutAHostIsInvalid() {
        for url in ["http://", "http:///onvif/device_service", "http://[fe80::1/onvif"] {
            XCTAssertEqual(ONVIFURLInput.address(in: url), refusal(ONVIFURLInput.invalidMessage), url)
        }
    }
}

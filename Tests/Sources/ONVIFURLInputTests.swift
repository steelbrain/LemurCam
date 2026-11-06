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
        XCTAssertEqual(ONVIFURLInput.address(in: login), refusal(ONVIFURLInput.loginMessage))
        XCTAssertEqual(
            ONVIFURLInput.address(in: "http://cam%2Fonvif/x"), refusal(ONVIFURLInput.notAnAddressMessage)
        )
    }

    /// The Host field's messages name that field and its Port field, and say to leave
    /// out `http://`, none of which fits the add form's URL field.
    func testTheAddFormSaysWhatIsWrongWithItsURL() {
        let cases = [
            "http://192.168.1.64%3A8080/onvif/device_service": ONVIFURLInput.notAnAddressMessage,
            "http://my%20cam.local/onvif/device_service": ONVIFURLInput.notAnAddressMessage,
            "http://admin%40192.168.1.64/onvif/device_service": ONVIFURLInput.loginMessage
        ]
        for (url, message) in cases {
            XCTAssertEqual(ONVIFURLInput.address(in: url), refusal(message), url)
        }
        for message in [ONVIFURLInput.loginMessage, ONVIFURLInput.notAnAddressMessage] {
            XCTAssertFalse(message.contains("here"), message)
            XCTAssertFalse(message.contains("Port field"), message)
        }
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

    /// A `/` in the password made the user name the host and the start of the password
    /// the port, and Fetch Profiles sent the form's login there.
    func testALoginTheAddressCantBeReadPastIsRefused() {
        for url in [
            "http://admin:1234/5@192.168.1.64/onvif/device_service",
            "http://admin:Admin#123@192.168.1.64/onvif/device_service"
        ] {
            XCTAssertEqual(ONVIFURLInput.address(in: url), refusal(ONVIFURLInput.ambiguousLoginMessage), url)
        }
        // This form keeps only the address: a login written with escapes, as the RTSP
        // field's message suggests, would be dropped.
        XCTAssertFalse(ONVIFURLInput.ambiguousLoginMessage.contains("%"))
        XCTAssertTrue(ONVIFURLInput.ambiguousLoginMessage.contains("Requires Authentication"))
    }

    func testAURLWithoutAHostIsInvalid() {
        for url in ["http://", "http:///onvif/device_service", "http://[fe80::1/onvif"] {
            XCTAssertEqual(ONVIFURLInput.address(in: url), refusal(ONVIFURLInput.invalidMessage), url)
        }
    }
}

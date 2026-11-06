@testable import LemurCam
import XCTest

/// The host of an ONVIF camera was taken as typed in its edit form. With a login in it
/// (`admin:secret@192.168.1.64`) the device service URL was still valid, so Fetch
/// Profiles worked, Save was enabled, and the login was saved in the cameras file and
/// shown in the camera list. The form now refuses a host with an `@`, `/`, `?`, `#`,
/// whitespace or a control character, saying what to enter instead.
internal final class ONVIFHostInputTests: XCTestCase {
    /// The URL `ONVIFClient` builds from such a host reads the login as userinfo.
    func testALoginInTheHostMadeAValidDeviceServiceURL() {
        let components = URLComponents(string: "http://admin:secret@192.168.1.64:80/onvif/device_service")
        XCTAssertEqual(components?.host, "192.168.1.64")
        XCTAssertEqual(components?.password, "secret")
    }

    func testALoginIsRefusedWithWhereToEnterIt() {
        for host in ["admin:secret@192.168.1.64", "admin@cam.local", "@192.168.1.64", "admin:p/ss@192.168.1.64"] {
            XCTAssertEqual(ONVIFHostInput.problem(with: host), ONVIFHostInput.loginMessage, host)
        }
        XCTAssertTrue(ONVIFHostInput.loginMessage.contains("Requires Authentication"))
    }

    func testWhatEndsAHostEarlyIsRefused() {
        let hosts = [
            "http://192.168.1.64", "192.168.1.64/onvif", "cam?x=1", "cam#1", "192.168.1.64 ", " cam.local",
            "front door", "cam\tlocal", "cam\n", "cam\u{7F}", "cam\u{A0}local"
        ]
        for host in hosts {
            let problem = ONVIFHostInput.problem(with: host)
            XCTAssertEqual(problem, ONVIFHostInput.notAnAddressMessage, host.debugDescription)
        }
    }

    /// Host names, IPv4 and IPv6 addresses, and an empty field, which Save and Fetch
    /// Profiles refuse on their own.
    func testAddressesPass() {
        let hosts = [
            "192.168.1.64", "cam.local", "CAM-01.example.com", "fe80::1", "[fe80::1]", "fe80::1%en0", "café.local", ""
        ]
        for host in hosts {
            XCTAssertNil(ONVIFHostInput.problem(with: host), host)
        }
    }
}

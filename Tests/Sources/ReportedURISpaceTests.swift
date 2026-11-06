@testable import LemurCam
import XCTest

/// IPCamKit refuses a URL with a space or a control character (its
/// `checkURLCharacters`). A stream URI a camera reported with one, and no login or `@`
/// to rewrite, was saved and connected to as reported, so the camera never streamed,
/// and an ONVIF camera has no URL field where the user could write `%20`. The same URI
/// with a login went with `%20`. Such a URI is now written with escapes.
internal final class ReportedURISpaceTests: XCTestCase {
    private func saved(_ uri: String, reportedBy camera: String = "192.168.1.20") -> String? {
        SourceCredentials.strippingUserInfo(fromReportedURI: uri, onvifHost: camera)
    }

    private func connected(_ uri: String, reportedBy camera: String = "192.168.1.20") -> String {
        StreamCoordinator.connectionTarget(forResolvedURI: uri, reportedBy: camera, savedCredentials: nil).url
    }

    func testASpaceIsWrittenAsAnEscape() {
        let cases = [
            "rtsp://192.168.1.20:554/Front Door": "rtsp://192.168.1.20:554/Front%20Door",
            "rtsp://192.168.1.20/live?name=Front Door": "rtsp://192.168.1.20/live?name=Front%20Door",
            "rtsp://192.168.1.20/a\tb": "rtsp://192.168.1.20/a%09b",
            // Split at the last `@`: the rest is written the same way.
            "rtsp://user:p#ss@192.168.1.20/Front Door": "rtsp://192.168.1.20/Front%20Door",
            // With a login URLComponents reads, as it already was.
            "rtsp://viewer:pw@192.168.1.20:554/Front Door": "rtsp://192.168.1.20:554/Front%20Door"
        ]
        for (uri, expected) in cases {
            XCTAssertEqual(saved(uri), expected, uri)
            XCTAssertEqual(connected(uri), expected, uri)
            XCTAssertEqual(saved(expected), expected, "\(uri): saving it again changes nothing")
        }
    }

    /// IPCamKit sends other characters `URLComponents` encodes as they are.
    func testOtherCharactersGoAsReported() {
        for uri in ["rtsp://192.168.1.20/a{b|c}", "rtsp://192.168.1.20:554/cam/realmonitor?channel=1&subtype=0"] {
            XCTAssertEqual(saved(uri), uri)
            XCTAssertEqual(connected(uri), uri)
        }
    }
}

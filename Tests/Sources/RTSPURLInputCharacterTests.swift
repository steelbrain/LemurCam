@testable import LemurCam
import XCTest

/// An RTSP URL with a space in it (`rtsp://192.0.2.5/live stream`) passed the form's
/// check, since `URLComponents` percent-encodes the space, and was saved; IPCamKit then
/// refused it on every connect (its `checkURLCharacters`: a space or a control
/// character would end the RTSP request line early). The form now refuses such a URL,
/// by IPCamKit's rule, with a message saying how to write it.
internal final class RTSPURLInputCharacterTests: XCTestCase {
    func testASpaceIsRefusedWithHowToWriteIt() {
        for url in [
            "rtsp://192.0.2.5/live stream", "rtsp://admin:pa ss@192.0.2.5/s", "rtsp://192.0.2.5/s?name=front door"
        ] {
            XCTAssertEqual(RTSPURLInput.problem(with: url), RTSPURLInput.spaceMessage, url)
        }
        XCTAssertTrue(RTSPURLInput.spaceMessage.contains("%20"))
    }

    func testAControlCharacterIsRefused() {
        for url in ["rtsp://192.0.2.5/live\tstream", "rtsp://192.0.2.5/s\r\nX-Header:1", "rtsp://192.0.2.5/s\u{7F}"] {
            XCTAssertEqual(RTSPURLInput.problem(with: url), RTSPURLInput.controlCharacterMessage, url.debugDescription)
        }
    }

    /// What IPCamKit accepts passes: an escaped space, non-ASCII characters (it
    /// percent-encodes them), and whitespace around the URL, which the form trims.
    func testWhatIPCamKitAcceptsStillPasses() {
        for url in ["rtsp://192.0.2.5/live%20stream", "rtsp://192.0.2.5/caméra", "rtsp://admin:pa%20ss@192.0.2.5/s"] {
            XCTAssertNil(RTSPURLInput.problem(with: url), url)
        }
        XCTAssertNil(RTSPURLInput.problem(with: RTSPURLInput.normalized("  rtsp://192.0.2.5/s \n")))
    }

    /// IPCamKit's rule, scalar by scalar: U+0000 to U+0020 and U+007F are refused, and
    /// nothing else in ASCII is.
    func testTheRuleIsIPCamKits() {
        for value in UInt32(0)...0x7F {
            guard let scalar = Unicode.Scalar(value) else { continue }
            let url = "rtsp://192.0.2.5/a" + String(Character(scalar)) + "b"
            let refused = value <= 0x20 || value == 0x7F
            XCTAssertEqual(RTSPURLInput.characterProblem(in: url) != nil, refused, "U+\(String(value, radix: 16))")
        }
    }
}

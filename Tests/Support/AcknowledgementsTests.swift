import XCTest

/// The MIT licenses of the code LemurCam is built on (UniCamEx, Retina through
/// IPCamKit, xmltree-rs through XMLKit, Apple's NullAudio sample) require their
/// notices in every copy of the software. The app as distributed carried none:
/// ACKNOWLEDGEMENTS.md stayed in the repository. It now ships in the app's resources.
internal final class AcknowledgementsTests: XCTestCase {
    func testTheAppCarriesTheThirdPartyNotices() throws {
        let url = try XCTUnwrap(
            Bundle.main.url(forResource: "ACKNOWLEDGEMENTS", withExtension: "md"),
            "ACKNOWLEDGEMENTS.md is not in the app's resources"
        )
        let notices = try String(contentsOf: url, encoding: .utf8)
        for project in ["UniCamEx", "Retina", "xmltree-rs", "NullAudio"] {
            XCTAssertTrue(notices.contains(project), "\(project)'s notice is missing")
        }
        XCTAssertTrue(notices.contains("The above copyright notice and this permission notice shall be included"))
    }
}

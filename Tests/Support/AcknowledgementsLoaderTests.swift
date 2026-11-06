@testable import LemurCam
import XCTest

/// The Acknowledgements window that About opens reads the notices the app bundles.
/// It must find them in the app (the unit-test host, so `Bundle.main`), and report
/// nil where they're missing so the window shows a message instead of a blank page.
internal final class AcknowledgementsLoaderTests: XCTestCase {
    func testTheAppsBundledNoticesLoad() throws {
        let notices = try XCTUnwrap(Acknowledgements.load(), "the app's ACKNOWLEDGEMENTS.md didn't load")
        XCTAssertFalse(notices.isEmpty)
        XCTAssertTrue(notices.hasPrefix("# Acknowledgements"))
        XCTAssertTrue(notices.contains("\n## NullAudio\n"))
    }

    func testABundleWithoutTheNoticesGivesNil() {
        // The test bundle carries only compiled tests, not the app's resources.
        XCTAssertNil(Acknowledgements.load(from: Bundle(for: Self.self)))
    }
}

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

    func testABlankNoticesFileGivesNil() throws {
        XCTAssertNil(Acknowledgements.load(from: try bundle(holdingNotices: " \n\n")))
    }

    func testNoticesLoadFromTheGivenBundle() throws {
        let notices = "# Acknowledgements\n\n## Example\n"
        XCTAssertEqual(Acknowledgements.load(from: try bundle(holdingNotices: notices)), notices)
    }

    /// A folder with only an ACKNOWLEDGEMENTS.md in it, opened as a bundle.
    private func bundle(holdingNotices notices: String) throws -> Bundle {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        try notices.write(
            to: directory.appendingPathComponent("ACKNOWLEDGEMENTS.md"), atomically: true, encoding: .utf8
        )
        return try XCTUnwrap(Bundle(url: directory))
    }
}

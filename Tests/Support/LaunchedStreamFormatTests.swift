@testable import LemurCam
import XCTest

/// Pins the "Restart to apply" rule: the notice shows exactly when the chosen
/// resolution or frame rate differs from what this launch started with, and goes
/// away again if the user picks the running values back.
internal final class LaunchedStreamFormatTests: XCTestCase {
    private let launched = LaunchedStreamFormat(resolution: .hd1080, frameRate: .fps60)

    func testRunningValuesNeedNoRestart() {
        XCTAssertFalse(launched.needsRestart(resolution: .hd1080, frameRate: .fps60))
    }

    func testChangedResolutionNeedsRestart() {
        XCTAssertTrue(launched.needsRestart(resolution: .uhd4k, frameRate: .fps60))
    }

    func testChangedFrameRateNeedsRestart() {
        XCTAssertTrue(launched.needsRestart(resolution: .hd1080, frameRate: .fps30))
    }

    func testChangingBackToRunningValuesClearsTheNotice() {
        XCTAssertTrue(launched.needsRestart(resolution: .hd720, frameRate: .fps30))
        XCTAssertFalse(launched.needsRestart(resolution: .hd1080, frameRate: .fps60))
    }
}

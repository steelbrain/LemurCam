@testable import LemurCam
import XCTest

/// Pins when becoming active re-checks the camera, the microphone and Launch at
/// Login. A launch guard's alert ("Move to Applications") can activate the app
/// before it quits; that activation used to send a camera query and a helper check
/// from a launch that never set anything up.
internal final class ActivationRefreshDecisionTests: XCTestCase {
    func testBecomingActiveAfterLaunchRefreshes() {
        XCTAssertTrue(ActivationRefreshDecision.refreshes(isTestHost: false, hasFinishedLaunching: true))
    }

    func testBecomingActiveBeforeLaunchFinishedRefreshesNothing() {
        // A launch guard's alert is up and the app is about to quit, or launch is still
        // making its own first checks.
        XCTAssertFalse(ActivationRefreshDecision.refreshes(isTestHost: false, hasFinishedLaunching: false))
    }

    func testBecomingActiveInTheTestHostRefreshesNothing() {
        XCTAssertFalse(ActivationRefreshDecision.refreshes(isTestHost: true, hasFinishedLaunching: true))
        XCTAssertFalse(ActivationRefreshDecision.refreshes(isTestHost: true, hasFinishedLaunching: false))
    }
}

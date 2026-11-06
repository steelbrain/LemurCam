@testable import LemurCam
import XCTest

/// Pins when the launch banner may appear. It waits for launch to finish (so it
/// can't flash ahead of the wizard) and yields to an open setup or Settings window,
/// but a setup step the user put off with "Set Up Later" no longer blocks it for
/// the rest of the session.
internal final class LaunchNudgeGateTests: XCTestCase {

    func testAllowedAfterLaunchWithNoWindowOpen() {
        // Also the "Set Up Later" case: the wizard is closed with a step pending,
        // and a later upgrade-pending state must still prompt.
        XCTAssertTrue(LaunchNudgeGate.canPresent(
            hasFinishedLaunching: true, setupWindowOpen: false, settingsWindowOpen: false
        ))
    }

    func testHeldBackDuringLaunch() {
        XCTAssertFalse(LaunchNudgeGate.canPresent(
            hasFinishedLaunching: false, setupWindowOpen: false, settingsWindowOpen: false
        ))
    }

    func testYieldsToOpenSetupWindow() {
        XCTAssertFalse(LaunchNudgeGate.canPresent(
            hasFinishedLaunching: true, setupWindowOpen: true, settingsWindowOpen: false
        ))
    }

    func testYieldsToOpenSettingsWindow() {
        XCTAssertFalse(LaunchNudgeGate.canPresent(
            hasFinishedLaunching: true, setupWindowOpen: false, settingsWindowOpen: true
        ))
    }
}

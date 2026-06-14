@testable import LemurCam
import XCTest

/// Pins which camera states earn a proactive launch banner. The contract: only
/// the two upgrade-pending restart states nudge; every other state (including a
/// fresh install awaiting approval, and the repair state) must stay silent so the
/// banner never fires when there is no missed upgrade to surface.
internal final class LaunchNudgeDecisionTests: XCTestCase {

    func testNeedsAppRestartNudgesForAppRestart() {
        XCTAssertEqual(LaunchNudgeDecision.evaluate(cameraStatus: .needsAppRestart), .appRestart)
    }

    func testNeedsRebootNudgesForReboot() {
        XCTAssertEqual(LaunchNudgeDecision.evaluate(cameraStatus: .needsReboot), .reboot)
    }

    func testNonUpgradeStatesDoNotNudge() {
        let silent: [CameraExtensionStatus] = [
            .unknown, .notInstalled, .installing, .awaitingApproval,
            .ready, .needsRepair, .failed("boom")
        ]
        for status in silent {
            XCTAssertNil(
                LaunchNudgeDecision.evaluate(cameraStatus: status),
                "Expected no launch nudge for \(status)"
            )
        }
    }
}

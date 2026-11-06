@testable import LemurCam
import XCTest

/// Pins what "Try Again" on a failed camera status redoes. It used to activate,
/// whatever had failed: after a failed repair, activating the version already
/// installed is cancelled as up to date, so the camera showed Running (and the
/// restart marker was cleared) while the duplicates the repair was removing stayed,
/// and the next refresh flipped back to Repair needed. It now redoes the request
/// that failed.
internal final class CameraRetryDecisionTests: XCTestCase {
    private let reason = CameraExtensionStatus.failed(
        "Installation was blocked by a system policy (such as MDM management)."
    )

    func testTryAgainRedoesAFailedRepair() {
        XCTAssertEqual(retry(after: .repair), .repair)
    }

    func testTryAgainRedoesAFailedActivation() {
        // Also a repair's reinstall that failed once every copy was removed: nothing
        // is installed, so activating is what is left to do.
        XCTAssertEqual(retry(after: .activation), .activation)
    }

    func testTryAgainActivatesWhenNothingFailed() {
        XCTAssertEqual(CameraStateDerivation.FailureHold().retry, .activation)
    }

    func testReCheckNowLeavesWhatTryAgainRedoes() {
        // Re-check Now lets the reason go, but when its query fails the status is still
        // the failed repair, and Try Again still redoes it.
        var hold = CameraStateDerivation.FailureHold()
        hold.requestFailed(.repair)
        hold.statusChanged(to: reason)
        hold.release()
        XCTAssertEqual(hold.retry, .repair)
    }

    func testTheLatestFailedRequestIsRedone() {
        // Try Again redid the repair: its removal went through and its reinstall failed.
        var hold = CameraStateDerivation.FailureHold()
        hold.requestFailed(.repair)
        hold.statusChanged(to: reason)
        hold.release()
        hold.statusChanged(to: .installing)
        hold.requestFailed(.activation)
        hold.statusChanged(to: reason)
        XCTAssertEqual(hold.retry, .activation)
    }

    func testAFailureNoLongerShownIsNotRedone() {
        // A reply replaced the failed repair's reason (the camera is enabled after all):
        // nothing failed is shown, so there is nothing to redo.
        var hold = CameraStateDerivation.FailureHold()
        hold.requestFailed(.repair)
        hold.statusChanged(to: .ready)
        XCTAssertEqual(hold.retry, .activation)
    }

    private func retry(after request: CameraStateDerivation.Request) -> CameraStateDerivation.Request {
        var hold = CameraStateDerivation.FailureHold()
        hold.requestFailed(request)
        hold.statusChanged(to: reason)
        return hold.retry
    }
}

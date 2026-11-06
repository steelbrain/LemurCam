@testable import LemurCam
import XCTest

/// Pins that a failed camera install's reason stays up until the user acts. The
/// setup window re-queries every 2.5 s and the app re-queries on every activation;
/// each reply that still found nothing installed used to replace the reason with
/// "Required. Enable the camera…" before it could be read.
internal final class CameraFailureHoldTests: XCTestCase {
    private let reason = CameraExtensionStatus.failed(
        "Installation was blocked by a system policy (such as MDM management)."
    )

    // MARK: - Install resolution

    func testANotInstalledReplyLeavesAHeldFailureUp() {
        XCTAssertEqual(
            CameraStateDerivation.resolveInstall(.notInstalled, isBusy: false, holdingFailure: true),
            .keepCurrent
        )
    }

    func testAnyOtherTopologyReplacesAHeldFailure() {
        let replies: [(ExtensionInstallClassification, CameraStateDerivation.InstallResolution)] = [
            (.awaitingApproval, .status(.awaitingApproval)),
            (.multipleVersions, .status(.needsRepair)),
            (.enabled, .deriveEnabled),
            (.disabled, .status(.disabled))
        ]
        for (classification, expected) in replies {
            XCTAssertEqual(
                CameraStateDerivation.resolveInstall(classification, isBusy: false, holdingFailure: true),
                expected, "\(classification)"
            )
        }
    }

    // MARK: - Hold lifecycle

    func testAFailedRequestHoldsItsReasonThroughEveryRoutineRefresh() {
        var hold = CameraStateDerivation.FailureHold()
        XCTAssertFalse(hold.isHolding)
        hold.requestFailed()
        hold.statusChanged(to: reason)

        // The setup window's polls and app activations: each reply finds nothing.
        var status = reason
        for _ in 0..<3 {
            status = apply(.notInstalled, to: status, hold: hold)
        }
        XCTAssertEqual(status, reason)
        XCTAssertTrue(hold.isHolding)
    }

    func testTheUsersNextCameraActionLetsTheReasonGo() {
        // Enable / Try Again, Repair and Re-check Now all release the hold, so what
        // their request or query finds is shown.
        var hold = CameraStateDerivation.FailureHold()
        hold.requestFailed()
        hold.statusChanged(to: reason)
        hold.release()

        XCTAssertFalse(hold.isHolding)
        XCTAssertEqual(apply(.notInstalled, to: reason, hold: hold), .notInstalled)
    }

    func testAnyStatusButAFailureEndsTheHold() {
        let others: [CameraExtensionStatus] = [
            .unknown, .notInstalled, .installing, .awaitingApproval, .disabled,
            .needsReboot, .needsAppRestart, .ready, .needsRepair
        ]
        for other in others {
            var hold = CameraStateDerivation.FailureHold()
            hold.requestFailed()
            hold.statusChanged(to: other)
            XCTAssertFalse(hold.isHolding, "\(other)")
        }
    }

    func testAnotherFailureKeepsTheHold() {
        var hold = CameraStateDerivation.FailureHold()
        hold.requestFailed()
        hold.statusChanged(to: .failed("The camera extension failed code-signature validation."))
        XCTAssertTrue(hold.isHolding)
    }

    func testAFailureReplacedByAnotherTopologyIsNotHeldAgain() {
        // Approval was asked for, then the extension went away: the reply that finds
        // nothing installed now shows that, not the old reason.
        var hold = CameraStateDerivation.FailureHold()
        hold.requestFailed()
        hold.statusChanged(to: reason)

        var status = apply(.awaitingApproval, to: reason, hold: hold)
        hold.statusChanged(to: status)
        status = apply(.notInstalled, to: status, hold: hold)
        XCTAssertEqual(status, .notInstalled)
    }

    func testNothingIsHeldBeforeARequestFails() {
        let hold = CameraStateDerivation.FailureHold()
        XCTAssertEqual(apply(.notInstalled, to: .unknown, hold: hold), .notInstalled)
    }

    /// The status a properties reply leaves, as `CameraExtensionController.applyProperties`
    /// applies it (the enabled derivation is out of scope here).
    private func apply(
        _ classification: ExtensionInstallClassification,
        to status: CameraExtensionStatus,
        hold: CameraStateDerivation.FailureHold
    ) -> CameraExtensionStatus {
        switch CameraStateDerivation.resolveInstall(classification, isBusy: false, holdingFailure: hold.isHolding) {
        case .status(let resolved): return resolved
        case .keepCurrent, .deriveEnabled: return status
        }
    }
}

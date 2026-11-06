@testable import LemurCam
import XCTest

/// Pins that a failed camera install's or repair's reason stays up until the user
/// acts. The setup window re-queries every 2.5 s and the app re-queries on every
/// activation; each reply that still found what the request was trying to change
/// (nothing installed, or the duplicates a repair was removing) used to replace the
/// reason with "Required. Enable the camera…" or "Repair needed" before it could be
/// read.
internal final class CameraFailureHoldTests: XCTestCase {
    private let reason = CameraExtensionStatus.failed(
        "Installation was blocked by a system policy (such as MDM management)."
    )
    private let topologies: [ExtensionInstallClassification] = [
        .notInstalled, .awaitingApproval, .multipleVersions, .enabled, .disabled
    ]

    // MARK: - Install resolution

    func testAReplyThatStillFindsTheHeldTopologyLeavesTheFailureUp() {
        for held: ExtensionInstallClassification in [.notInstalled, .multipleVersions] {
            XCTAssertEqual(
                CameraStateDerivation.resolveInstall(held, isBusy: false, heldTopology: held),
                .keepCurrent, "\(held)"
            )
        }
    }

    func testAnyOtherTopologyReplacesAHeldFailure() {
        let resolutions: [ExtensionInstallClassification: CameraStateDerivation.InstallResolution] = [
            .notInstalled: .status(.notInstalled),
            .awaitingApproval: .status(.awaitingApproval),
            .multipleVersions: .status(.needsRepair),
            .enabled: .deriveEnabled,
            .disabled: .status(.disabled)
        ]
        for held: ExtensionInstallClassification in [.notInstalled, .multipleVersions] {
            for classification in topologies where classification != held {
                XCTAssertEqual(
                    CameraStateDerivation.resolveInstall(classification, isBusy: false, heldTopology: held),
                    resolutions[classification], "\(classification) over a hold against \(held)"
                )
            }
        }
    }

    // MARK: - What each failed request is held against

    func testAFailedActivationIsHeldAgainstNothingInstalled() {
        var hold = CameraStateDerivation.FailureHold()
        hold.requestFailed(.activation)
        hold.statusChanged(to: reason)
        XCTAssertEqual(hold.heldTopology, .notInstalled)
    }

    func testAFailedRepairIsHeldAgainstTheDuplicatesItWasRemoving() {
        var hold = CameraStateDerivation.FailureHold()
        hold.requestFailed(.repair)
        hold.statusChanged(to: reason)
        XCTAssertEqual(hold.heldTopology, .multipleVersions)
    }

    // MARK: - Hold lifecycle

    func testAFailedActivationHoldsItsReasonThroughEveryRoutineRefresh() {
        XCTAssertEqual(refreshes(after: .activation, finding: .notInstalled), reason)
    }

    func testAFailedRepairHoldsItsReasonWhileTheDuplicatesStay() {
        // The repair's removal failed, so every copy is still installed: the replies
        // find more than one version, which used to show "Repair needed" over the reason.
        XCTAssertEqual(refreshes(after: .repair, finding: .multipleVersions), reason)
    }

    func testAFailedActivationIsNotHeldAgainstDuplicates() {
        XCTAssertEqual(refreshes(after: .activation, finding: .multipleVersions), .needsRepair)
    }

    func testAFailedRepairIsNotHeldAgainstNothingInstalled() {
        // The removal got through after all: the reply says more than the reason.
        XCTAssertEqual(refreshes(after: .repair, finding: .notInstalled), .notInstalled)
    }

    func testTheUsersNextCameraActionLetsTheReasonGo() {
        // Enable / Try Again, Repair and Re-check Now all release the hold, so what
        // their request or query finds is shown.
        for request: CameraStateDerivation.Request in [.activation, .repair] {
            var hold = CameraStateDerivation.FailureHold()
            hold.requestFailed(request)
            hold.statusChanged(to: reason)
            hold.release()

            XCTAssertFalse(hold.isHolding, "\(request)")
            XCTAssertNil(hold.heldTopology, "\(request)")
            XCTAssertEqual(apply(.notInstalled, to: reason, hold: hold), .notInstalled, "\(request)")
            XCTAssertEqual(apply(.multipleVersions, to: reason, hold: hold), .needsRepair, "\(request)")
        }
    }

    func testAnyStatusButAFailureEndsTheHold() {
        let others: [CameraExtensionStatus] = [
            .unknown, .notInstalled, .installing, .awaitingApproval, .disabled,
            .needsReboot, .needsAppRestart, .ready, .needsRepair
        ]
        for request: CameraStateDerivation.Request in [.activation, .repair] {
            for other in others {
                var hold = CameraStateDerivation.FailureHold()
                hold.requestFailed(request)
                hold.statusChanged(to: other)
                XCTAssertFalse(hold.isHolding, "\(request) → \(other)")
                XCTAssertNil(hold.failedRequest, "\(request) → \(other)")
            }
        }
    }

    func testAnotherFailureKeepsTheHold() {
        var hold = CameraStateDerivation.FailureHold()
        hold.requestFailed(.repair)
        hold.statusChanged(to: .failed("The camera extension failed code-signature validation."))
        XCTAssertTrue(hold.isHolding)
        XCTAssertEqual(hold.heldTopology, .multipleVersions)
    }

    func testTheLatestFailedRequestDecidesWhatIsHeld() {
        // A repair's removal went through, then its reinstall failed: nothing is
        // installed now, and that is what the reason is held against.
        var hold = CameraStateDerivation.FailureHold()
        hold.requestFailed(.repair)
        hold.requestFailed(.activation)
        XCTAssertEqual(hold.heldTopology, .notInstalled)
    }

    func testAFailureReplacedByAnotherTopologyIsNotHeldAgain() {
        // Approval was asked for, then the extension went away: the reply that finds
        // nothing installed now shows that, not the old reason.
        var hold = CameraStateDerivation.FailureHold()
        hold.requestFailed(.activation)
        hold.statusChanged(to: reason)

        var status = apply(.awaitingApproval, to: reason, hold: hold)
        hold.statusChanged(to: status)
        status = apply(.notInstalled, to: status, hold: hold)
        XCTAssertEqual(status, .notInstalled)
    }

    func testNothingIsHeldBeforeARequestFails() {
        let hold = CameraStateDerivation.FailureHold()
        XCTAssertNil(hold.heldTopology)
        XCTAssertEqual(apply(.notInstalled, to: .unknown, hold: hold), .notInstalled)
        XCTAssertEqual(apply(.multipleVersions, to: .unknown, hold: hold), .needsRepair)
    }

    /// The status left after `request` failed and three routine refreshes (the setup
    /// window's polls, app activations) each found `topology`, with the hold updated
    /// as the controller updates it.
    private func refreshes(
        after request: CameraStateDerivation.Request,
        finding topology: ExtensionInstallClassification
    ) -> CameraExtensionStatus {
        var hold = CameraStateDerivation.FailureHold()
        hold.requestFailed(request)
        hold.statusChanged(to: reason)
        var status = reason
        for _ in 0..<3 {
            status = apply(topology, to: status, hold: hold)
            hold.statusChanged(to: status)
        }
        return status
    }

    /// The status a properties reply leaves, as `CameraExtensionController.applyProperties`
    /// applies it (the enabled derivation is out of scope here).
    private func apply(
        _ classification: ExtensionInstallClassification,
        to status: CameraExtensionStatus,
        hold: CameraStateDerivation.FailureHold
    ) -> CameraExtensionStatus {
        switch CameraStateDerivation.resolveInstall(classification, isBusy: false, heldTopology: hold.heldTopology) {
        case .status(let resolved): return resolved
        case .keepCurrent, .deriveEnabled: return status
        }
    }
}

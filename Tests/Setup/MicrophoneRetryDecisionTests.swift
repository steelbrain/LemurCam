@testable import LemurCam
import XCTest

/// Pins what "Try Again" does on a failed microphone status. An install or removal
/// the helper answered as failed is redone: the helper can have put the files in
/// place and then failed to restart coreaudiod, which a check would mistake for
/// done. After one the helper never answered, it re-checks first and only redoes it
/// when the check shows it is still needed: installing restarts coreaudiod, cutting
/// audio in every app (in the middle of a call, say), so a helper that was only
/// briefly unreachable must not cause it.
internal final class MicrophoneRetryDecisionTests: XCTestCase {
    private func check(_ version: String?, sealed: Bool = true) -> InstalledDriverCheck {
        InstalledDriverCheck(reachable: true, version: version, sealed: sealed)
    }

    // MARK: - Redo or check first

    private func retry(_ failure: MicrophoneOperationFailure?, helperEnabled: Bool = true) -> MicrophoneRetry {
        MicrophoneRetry.decide(helperEnabled: helperEnabled, operationRunning: false, failure: failure)
    }

    func testAFailureTheHelperReportedIsRedone() {
        for operation: MicrophoneDriverOperation in [.install, .remove] {
            XCTAssertEqual(
                retry(MicrophoneOperationFailure(operation: operation, reportedByHelper: true)), .redo(operation)
            )
        }
    }

    func testAnOperationTheHelperNeverAnsweredIsCheckedFirst() {
        for operation: MicrophoneDriverOperation in [.install, .remove] {
            XCTAssertEqual(
                retry(MicrophoneOperationFailure(operation: operation, reportedByHelper: false)), .checkFirst
            )
        }
        XCTAssertEqual(retry(nil), .checkFirst, "only a check failed")
    }

    func testAHelperNotApprovedContinuesSetup() {
        XCTAssertEqual(
            retry(MicrophoneOperationFailure(operation: .install, reportedByHelper: true), helperEnabled: false),
            .continueSetup
        )
    }

    func testNothingStartsWhileAnOperationRuns() {
        XCTAssertEqual(
            MicrophoneRetry.decide(
                helperEnabled: true, operationRunning: true,
                failure: MicrophoneOperationFailure(operation: .install, reportedByHelper: true)
            ),
            .ignore
        )
    }

    func testTheHelpersReplyIsAnAnswer() {
        // The reply signature is the one v1.5 helpers answer with: success == false
        // is the helper reporting a failure, not an unreachable helper.
        XCTAssertEqual(MicrophoneOperationResult(success: true, message: ""), .succeeded)
        XCTAssertEqual(
            MicrophoneOperationResult(success: false, message: "Driver installed but coreaudiod restart failed: x"),
            .failed("Driver installed but coreaudiod restart failed: x")
        )
    }

    // MARK: - Checking first

    /// "Try Again" checking first after the helper never answered `failed` (nil:
    /// only a check failed).
    private func retry(
        after failed: MicrophoneDriverOperation?, _ check: InstalledDriverCheck, staleHelperSeen: Bool = false
    ) -> MicrophoneVersionReply {
        MicrophoneVersionReply.decide(check, context: MicrophoneCheckContext(
            currentStatus: .unknown, retrying: true, lastOperation: failed,
            staleHelperSeen: staleHelperSeen, bundledVersion: "6"
        ))
    }

    func testRetryAfterAFailedCheckOnlyChecks() {
        // The helper was unreachable; nothing was being installed. Whatever the
        // check finds is shown with its own action, never installed by itself (no
        // driver here means the user removed the microphone).
        XCTAssertEqual(retry(after: nil, check("6")), .setStatus(.ready))
        XCTAssertEqual(retry(after: nil, check("5")), .setStatus(.ready))
        XCTAssertEqual(retry(after: nil, check("6", sealed: false)), .setStatus(.ready))
        XCTAssertEqual(retry(after: nil, check(nil)), .setStatus(.notSetUp))
    }

    func testRetryAfterAnUnansweredInstallInstallsOnlyWhenStillNeeded() {
        XCTAssertEqual(retry(after: .install, check(nil)), .installDriver, "no driver")
        XCTAssertEqual(retry(after: .install, check("5")), .installDriver, "an update")
        XCTAssertEqual(retry(after: .install, check("6", sealed: false)), .installDriver, "an unsealed copy")
        XCTAssertEqual(retry(after: .install, check("6")), .setStatus(.ready), "it had worked: no coreaudiod restart")
    }

    func testRetryNeverReinstallsThroughAStaleHelper() {
        XCTAssertEqual(
            retry(after: .install, check("6", sealed: false), staleHelperSeen: true), .setStatus(.needsReboot)
        )
    }

    func testRetryAfterAnUnansweredRemovalRemovesOnlyWhatIsStillInstalled() {
        XCTAssertEqual(retry(after: .remove, check("6")), .uninstallDriver)
        XCTAssertEqual(retry(after: .remove, check(nil)), .setStatus(.notSetUp), "it had worked")
    }

    func testOnlyARetryRedoesTheLastOperation() {
        // A routine refresh (app reactivation) after a failed install shows the state
        // with its own action; it never installs by itself.
        let context = MicrophoneCheckContext(
            currentStatus: .failed("Driver installation failed."), lastOperation: .install, bundledVersion: "6"
        )
        XCTAssertEqual(MicrophoneVersionReply.decide(check(nil), context: context), .setStatus(.notSetUp))
        XCTAssertEqual(MicrophoneVersionReply.decide(check("5"), context: context), .setStatus(.ready))
    }

    func testRetryThatCannotReachTheHelperFailsAgain() {
        XCTAssertEqual(
            MicrophoneVersionReply.decide(.unreachable, context: MicrophoneCheckContext(
                currentStatus: .unknown, retrying: true, lastOperation: .install, bundledVersion: "6"
            )),
            .setStatus(.failed(MicrophoneVersionReply.unreachableMessage))
        )
    }
}

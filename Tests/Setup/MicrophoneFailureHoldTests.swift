@testable import LemurCam
import XCTest

/// Pins that a failed install or removal keeps its reason up until the user acts.
/// The guided setup window refreshes every 2.5 s, and each refresh that reached the
/// helper used to replace the failure with Not Set Up or Ready, so the reason was
/// gone before it could be read.
internal final class MicrophoneFailureHoldTests: XCTestCase {
    private let failed = MicrophoneStatus.failed("Driver installed but coreaudiod restart failed: x")

    func testAHeldFailureSurvivesEveryCheck() {
        let checks: [InstalledDriverCheck] = [
            InstalledDriverCheck(reachable: true, version: "6", sealed: true),
            InstalledDriverCheck(reachable: true, version: "6", sealed: false),
            InstalledDriverCheck(reachable: true, version: nil, sealed: false),
            .unreachable
        ]
        for check in checks {
            let context = MicrophoneCheckContext(
                currentStatus: failed, autoInstallPending: true, verifyingInstall: true,
                bundledVersion: "6", holdingFailure: true
            )
            XCTAssertEqual(MicrophoneVersionReply.decide(check, context: context), .keepStatus, "\(check)")
        }
    }

    func testAFailureNotHeldIsReplacedByTheNextCheck() {
        // A failed check (not an operation) is not held: the next check that reaches
        // the helper shows the real state.
        let context = MicrophoneCheckContext(
            currentStatus: .failed(MicrophoneVersionReply.unreachableMessage), bundledVersion: "6"
        )
        XCTAssertEqual(
            MicrophoneVersionReply.decide(InstalledDriverCheck(reachable: true, version: "6", sealed: true),
                                          context: context),
            .setStatus(.ready)
        )
    }

    func testRefreshLeavesAHeldFailureWhateverTheHelpersState() {
        for state: AudioDeviceInstaller.State in [.notRegistered, .notFound, .requiresApproval] {
            XCTAssertEqual(
                MicrophoneRefresh.decide(helper: state, operationRunning: false, holdingFailure: true),
                .keepStatus, "\(state)"
            )
        }
        // The installed version and seal are still read behind it.
        XCTAssertEqual(
            MicrophoneRefresh.decide(helper: .enabled, operationRunning: false, holdingFailure: true), .checkDriver
        )
    }

    func testRefreshShowsTheHelpersStateOtherwise() {
        XCTAssertEqual(
            MicrophoneRefresh.decide(helper: .notRegistered, operationRunning: false, holdingFailure: false),
            .setStatus(.notSetUp)
        )
        XCTAssertEqual(
            MicrophoneRefresh.decide(helper: .notFound, operationRunning: false, holdingFailure: false),
            .setStatus(.notSetUp)
        )
        XCTAssertEqual(
            MicrophoneRefresh.decide(helper: .requiresApproval, operationRunning: false, holdingFailure: false),
            .setStatus(.needsApproval)
        )
        XCTAssertEqual(
            MicrophoneRefresh.decide(helper: .enabled, operationRunning: false, holdingFailure: false), .checkDriver
        )
    }

    func testRefreshLeavesARunningOperationAlone() {
        // Its progress stays up, and no check is sent: the helper would answer it only
        // after the operation, which is then checked on its own.
        for state: AudioDeviceInstaller.State in [.enabled, .notRegistered, .notFound, .requiresApproval] {
            XCTAssertEqual(
                MicrophoneRefresh.decide(helper: state, operationRunning: true, holdingFailure: false),
                .keepStatus, "\(state)"
            )
        }
    }
}

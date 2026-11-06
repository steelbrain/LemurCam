@testable import LemurCam
import XCTest

/// Pins the camera controller's load-bearing state-machine glue, extracted so it
/// can be tested without SystemExtensions/CoreMediaIO. The core invariant: never
/// resolve to `.ready` while stale code runs (liveness gate + version handshake),
/// and never downgrade a status mid-request (the `isBusy` race guards).
internal final class CameraStateDerivationTests: XCTestCase {

    // MARK: - Install resolution

    func testNotInstalledOnlyWhenIdle() {
        XCTAssertEqual(
            CameraStateDerivation.resolveInstall(.notInstalled, isBusy: false, heldTopology: nil),
            .status(.notInstalled)
        )
        // A racing empty reply mid-activation must not clobber the in-flight state.
        XCTAssertEqual(
            CameraStateDerivation.resolveInstall(.notInstalled, isBusy: true, heldTopology: nil),
            .keepCurrent
        )
    }

    func testMultipleVersionsNeedsRepairOnlyWhenIdle() {
        XCTAssertEqual(
            CameraStateDerivation.resolveInstall(.multipleVersions, isBusy: false, heldTopology: nil),
            .status(.needsRepair)
        )
        // Transient duplicate while our own request is in flight: don't flag repair.
        XCTAssertEqual(
            CameraStateDerivation.resolveInstall(.multipleVersions, isBusy: true, heldTopology: nil),
            .keepCurrent
        )
    }

    func testAwaitingApprovalIsAlwaysSurfaced() {
        XCTAssertEqual(
            CameraStateDerivation.resolveInstall(.awaitingApproval, isBusy: false, heldTopology: nil),
            .status(.awaitingApproval)
        )
        XCTAssertEqual(
            CameraStateDerivation.resolveInstall(.awaitingApproval, isBusy: true, heldTopology: nil),
            .status(.awaitingApproval)
        )
    }

    func testEnabledDefersToLivenessDerivation() {
        XCTAssertEqual(
            CameraStateDerivation.resolveInstall(.enabled, isBusy: false, heldTopology: nil), .deriveEnabled
        )
        XCTAssertEqual(
            CameraStateDerivation.resolveInstall(.enabled, isBusy: true, heldTopology: nil), .deriveEnabled
        )
    }

    func testDisabledShowsDistinctDisabledIdleAndInstallingWhenBusy() {
        // M2: a switched-off (or uninstalling) single extension is its own state, not
        // "awaiting approval" — the user already approved it once and turned it off.
        XCTAssertEqual(
            CameraStateDerivation.resolveInstall(.disabled, isBusy: false, heldTopology: nil),
            .status(.disabled)
        )
        XCTAssertEqual(
            CameraStateDerivation.resolveInstall(.disabled, isBusy: true, heldTopology: nil),
            .status(.installing)
        )
    }

    // MARK: - Enabled-state derivation

    func testNotLiveWhileSettlingShowsInstalling() {
        // The liveness gate: a not-live device is never ready. From a non-committed
        // status it settles as installing (the version handshake is moot when offline).
        for status: CameraExtensionStatus in [.unknown, .installing, .notInstalled, .awaitingApproval] {
            XCTAssertEqual(
                CameraStateDerivation.deriveEnabledState(
                    isLive: false, currentStatus: status, upgradeState: .upToDate, rebootPending: false
                ),
                .installing
            )
        }
    }

    func testNotLiveDoesNotBounceCommittedState() {
        // The oscillation fix: a periodic refresh that finds the device not live must
        // NOT revert a committed post-install decision (or confirmed-ready) back to
        // installing — it leaves the status untouched.
        for status: CameraExtensionStatus in [.ready, .needsAppRestart, .needsReboot] {
            XCTAssertEqual(
                CameraStateDerivation.deriveEnabledState(
                    isLive: false, currentStatus: status, upgradeState: .upToDate, rebootPending: false
                ),
                .keepCurrent
            )
        }
    }

    func testRebootPendingGoesStraightToReboot() {
        // An old version staged to uninstall on reboot: don't loop on app restart —
        // the swap completes only after a reboot. Overrides the installing settle even
        // from a fresh status.
        XCTAssertEqual(
            CameraStateDerivation.deriveEnabledState(
                isLive: false, currentStatus: .installing, upgradeState: .upToDate, rebootPending: true
            ),
            .reboot
        )
        XCTAssertEqual(
            CameraStateDerivation.deriveEnabledState(
                isLive: false, currentStatus: .needsAppRestart, upgradeState: .upToDate, rebootPending: true
            ),
            .reboot
        )
    }

    func testLiveMatchingVersionIsReady() {
        // Once the device is actually live, a pending old-version uninstall is just
        // cleanup — the new version is serving, so it's ready.
        XCTAssertEqual(
            CameraStateDerivation.deriveEnabledState(
                isLive: true, currentStatus: .installing, upgradeState: .upToDate, rebootPending: true
            ),
            .ready
        )
    }

    func testLiveStaleVersionWantsAppRestart() {
        XCTAssertEqual(
            CameraStateDerivation.deriveEnabledState(
                isLive: true, currentStatus: .installing, upgradeState: .appRestartRequired, rebootPending: false
            ),
            .appRestart
        )
    }

    func testLiveStaleVersionWithRebootPendingWantsReboot() {
        // An old version staged to uninstall on reboot means macOS deferred the swap
        // until a reboot; relaunching the app would just bring the stale extension
        // back, so this must prompt a reboot rather than an app restart.
        XCTAssertEqual(
            CameraStateDerivation.deriveEnabledState(
                isLive: true, currentStatus: .installing, upgradeState: .appRestartRequired, rebootPending: true
            ),
            .reboot
        )
        XCTAssertEqual(
            CameraStateDerivation.deriveEnabledState(
                isLive: true, currentStatus: .needsAppRestart, upgradeState: .appRestartRequired, rebootPending: true
            ),
            .reboot
        )
    }

    func testLiveRebootStateWantsReboot() {
        XCTAssertEqual(
            CameraStateDerivation.deriveEnabledState(
                isLive: true, currentStatus: .needsAppRestart, upgradeState: .rebootRequired, rebootPending: false
            ),
            .reboot
        )
    }

    // MARK: - Poll-timeout escalation

    func testPollTimeoutPromptsRestartFirstThenEscalates() {
        // First timeout: prompt one app restart (often makes the device appear).
        XCTAssertEqual(
            CameraStateDerivation.resolvePollTimeout(restartAlreadyTried: false),
            .promptRestart
        )
        // Already restarted and the device is still absent → escalate to reboot,
        // never loop on app restart and never fake .ready.
        XCTAssertEqual(
            CameraStateDerivation.resolvePollTimeout(restartAlreadyTried: true),
            .escalateReboot
        )
    }

    // MARK: - Poll-timeout gate

    func testPollTimeoutResolvesOnlyWhileInstallingAndIdle() {
        var gate = CameraStateDerivation.PollTimeoutGate()
        XCTAssertTrue(gate.pollTimedOut(currentStatus: .installing, isBusy: false))
        XCTAssertFalse(gate.isDeferred)

        for status: CameraExtensionStatus in [.ready, .awaitingApproval, .needsAppRestart, .needsReboot, .disabled] {
            var other = CameraStateDerivation.PollTimeoutGate()
            XCTAssertFalse(other.pollTimedOut(currentStatus: status, isBusy: false), "\(status)")
            XCTAssertFalse(other.isDeferred, "\(status)")
        }
    }

    func testPollTimeoutDuringAnInFlightRequestIsDeferred() {
        // B8: an activation slower than the poll budget used to show a false restart
        // prompt and record the restart marker (a reboot prompt on the next launch).
        var gate = CameraStateDerivation.PollTimeoutGate()
        XCTAssertFalse(gate.pollTimedOut(currentStatus: .installing, isBusy: true))
        XCTAssertTrue(gate.isDeferred)
    }

    func testDeferredTimeoutRestartsThePollOnceTheRequestLandsStillInstalling() {
        var gate = CameraStateDerivation.PollTimeoutGate()
        _ = gate.pollTimedOut(currentStatus: .installing, isBusy: true)

        XCTAssertFalse(gate.stateSettled(currentStatus: .installing, isBusy: true), "request still in flight")
        XCTAssertTrue(gate.isDeferred)

        XCTAssertTrue(gate.stateSettled(currentStatus: .installing, isBusy: false))
        XCTAssertFalse(gate.isDeferred)
        XCTAssertFalse(gate.stateSettled(currentStatus: .installing, isBusy: false), "re-armed only once")
    }

    func testDeferredTimeoutIsDroppedWhenTheRequestResolvesTheStatus() {
        var gate = CameraStateDerivation.PollTimeoutGate()
        _ = gate.pollTimedOut(currentStatus: .installing, isBusy: true)
        XCTAssertFalse(gate.stateSettled(currentStatus: .ready, isBusy: false))
        XCTAssertFalse(gate.isDeferred)

        var changed = CameraStateDerivation.PollTimeoutGate()
        _ = changed.pollTimedOut(currentStatus: .installing, isBusy: true)
        changed.statusChanged()
        XCTAssertFalse(changed.isDeferred)
        XCTAssertFalse(changed.stateSettled(currentStatus: .installing, isBusy: false))
    }

    func testSettlingWithoutADeferredTimeoutDoesNothing() {
        var gate = CameraStateDerivation.PollTimeoutGate()
        XCTAssertFalse(gate.stateSettled(currentStatus: .installing, isBusy: false))
    }

    func testUnknownRunningVersionResolvesReadyBehindLiveness() {
        // Pre-handshake extension (never stamps → .unknown): don't false-alarm —
        // once the device is live, ready.
        XCTAssertEqual(
            CameraStateDerivation.deriveEnabledState(
                isLive: true, currentStatus: .installing, upgradeState: .unknown, rebootPending: false
            ),
            .ready
        )
    }
}

@testable import LemurCam
import XCTest

/// Locks the guided-setup step ordering, the launch auto-open decision, and the
/// per-version reset persistence. The wizard's navigation, its "resume on the
/// first incomplete step" behavior, and "reset on app update" all hinge on these,
/// so pin them explicitly.
internal final class SetupStepTests: XCTestCase {

    // MARK: - Ordering

    func testDisplayNumberIsOneBased() {
        XCTAssertEqual(SetupStep.camera.displayNumber, 1)
        XCTAssertEqual(SetupStep.microphone.displayNumber, 2)
        XCTAssertEqual(SetupStep.addCamera.displayNumber, 3)
    }

    func testTotalMatchesCaseCount() {
        XCTAssertEqual(SetupStep.total, 3)
        XCTAssertEqual(SetupStep.allCases, [.camera, .microphone, .addCamera])
    }

    func testNextWalksForwardThenStops() {
        XCTAssertEqual(SetupStep.camera.next, .microphone)
        XCTAssertEqual(SetupStep.microphone.next, .addCamera)
        XCTAssertNil(SetupStep.addCamera.next)
    }

    func testPreviousWalksBackwardThenStops() {
        XCTAssertNil(SetupStep.camera.previous)
        XCTAssertEqual(SetupStep.microphone.previous, .camera)
        XCTAssertEqual(SetupStep.addCamera.previous, .microphone)
    }

    // MARK: - Launch decision

    func testFirstRunOpensAtCamera() {
        XCTAssertEqual(
            SetupLaunchDecision.step(step1Done: false, step2Done: false, step3Done: false),
            .camera
        )
    }

    func testResumesAtFirstIncompleteStep() {
        XCTAssertEqual(
            SetupLaunchDecision.step(step1Done: true, step2Done: false, step3Done: false),
            .microphone
        )
        XCTAssertEqual(
            SetupLaunchDecision.step(step1Done: true, step2Done: true, step3Done: false),
            .addCamera
        )
    }

    func testCompletedSetupDoesNotAutoOpen() {
        XCTAssertNil(SetupLaunchDecision.step(step1Done: true, step2Done: true, step3Done: true))
    }

    func testRestartDuringStepOneReopensAtCamera() {
        // Approving the camera extension and restarting does not mark step 1
        // done (only an explicit Next does), so the wizard must reopen on step 1
        // rather than skipping ahead to the microphone step.
        XCTAssertEqual(
            SetupLaunchDecision.step(step1Done: false, step2Done: false, step3Done: false),
            .camera
        )
    }

    func testEarliestIncompleteStepWinsRegardlessOfLaterFlags() {
        XCTAssertEqual(
            SetupLaunchDecision.step(step1Done: false, step2Done: true, step3Done: true),
            .camera
        )
        XCTAssertEqual(
            SetupLaunchDecision.step(step1Done: true, step2Done: false, step3Done: true),
            .microphone
        )
    }

    // MARK: - Footer buttons

    func testCameraStepDefersOnlyUntilReady() {
        // Not ready (the awaiting-approval / not-installed state in the screenshot):
        // the only footer action is "Set Up Later", and no disabled Continue.
        XCTAssertEqual(SetupFooterButtons.leading(for: .camera, cameraStepDone: false), .setUpLater)
        XCTAssertNil(SetupFooterButtons.primary(for: .camera, cameraStepDone: false, micReady: false))
    }

    func testCameraStepShowsContinueOnceReady() {
        // Ready: "Set Up Later" empties and "Continue" takes the primary slot.
        XCTAssertNil(SetupFooterButtons.leading(for: .camera, cameraStepDone: true))
        XCTAssertEqual(
            SetupFooterButtons.primary(for: .camera, cameraStepDone: true, micReady: false),
            .continueStep
        )
    }

    func testCameraStepNeverShowsDeferAndContinueTogether() {
        // The whole point: Set Up Later and Continue are mutually exclusive.
        for done in [false, true] {
            let leading = SetupFooterButtons.leading(for: .camera, cameraStepDone: done)
            let primary = SetupFooterButtons.primary(for: .camera, cameraStepDone: done, micReady: false)
            XCTAssertFalse(
                leading == .setUpLater && primary == .continueStep,
                "Set Up Later and Continue must not both show (cameraStepDone: \(done))"
            )
        }
    }

    func testMicrophoneStepUsesBackAndSkipUntilReady() {
        XCTAssertEqual(SetupFooterButtons.leading(for: .microphone, cameraStepDone: true), .back)
        XCTAssertEqual(
            SetupFooterButtons.primary(for: .microphone, cameraStepDone: true, micReady: false),
            .skip
        )
        XCTAssertEqual(
            SetupFooterButtons.primary(for: .microphone, cameraStepDone: true, micReady: true),
            .continueStep
        )
    }

    func testAddCameraStepUsesBackAndDone() {
        XCTAssertEqual(SetupFooterButtons.leading(for: .addCamera, cameraStepDone: true), .back)
        XCTAssertEqual(
            SetupFooterButtons.primary(for: .addCamera, cameraStepDone: true, micReady: false),
            .done
        )
    }

    // MARK: - Camera-step advance gate

    func testCameraStepAdvancesOnlyWhenReady() {
        XCTAssertTrue(SetupCameraGate.canAdvance(.ready))
    }

    func testCameraStepDoesNotAdvanceWhileRestartRequired() {
        // A pending app restart or Mac reboot must be taken first — no Continue.
        for status: CameraExtensionStatus in [
            .unknown, .notInstalled, .installing, .awaitingApproval,
            .needsAppRestart, .needsReboot, .needsRepair, .failed("boom")
        ] {
            XCTAssertFalse(SetupCameraGate.canAdvance(status), "Should not advance on \(status)")
        }
    }

    // MARK: - Version-reset decision

    func testFirstLaunchNeedsReset() {
        // No version recorded yet: treat as a fresh install and reset.
        XCTAssertTrue(
            SetupLaunchDecision.needsResetForVersion(storedVersion: nil, currentVersion: "1.5 (42)")
        )
    }

    func testSameVersionDoesNotReset() {
        XCTAssertFalse(
            SetupLaunchDecision.needsResetForVersion(storedVersion: "1.5 (42)", currentVersion: "1.5 (42)")
        )
    }

    func testNewMarketingVersionResets() {
        XCTAssertTrue(
            SetupLaunchDecision.needsResetForVersion(storedVersion: "1.4 (42)", currentVersion: "1.5 (42)")
        )
    }

    func testNewBuildNumberResets() {
        XCTAssertTrue(
            SetupLaunchDecision.needsResetForVersion(storedVersion: "1.5 (41)", currentVersion: "1.5 (42)")
        )
    }

    // MARK: - SetupStateStore (version-scoped persistence)

    func testStoreFirstLaunchResetsAndOpensAtCamera() throws {
        let defaults = try freshDefaults("firstLaunch")
        let store = SetupStateStore(defaults: defaults, version: "1.0 (1)")

        XCTAssertTrue(store.resetForVersionChangeIfNeeded(), "first launch should reset")
        XCTAssertFalse(store.isComplete(.camera))
        XCTAssertEqual(store.launchStep(), .camera)
    }

    func testStoreMarkCompleteAdvancesAndPersists() throws {
        let defaults = try freshDefaults("markComplete")
        let store = SetupStateStore(defaults: defaults, version: "1.0 (1)")
        store.resetForVersionChangeIfNeeded()

        store.markComplete(.camera)
        XCTAssertTrue(store.isComplete(.camera))
        XCTAssertEqual(store.launchStep(), .microphone)

        store.markComplete(.microphone)
        store.markComplete(.addCamera)
        XCTAssertNil(store.launchStep(), "every step done should stop auto-opening")
    }

    func testStoreSameVersionPreservesCompletion() throws {
        let defaults = try freshDefaults("sameVersion")
        let first = SetupStateStore(defaults: defaults, version: "1.0 (1)")
        first.resetForVersionChangeIfNeeded()
        first.markComplete(.camera)
        first.markComplete(.microphone)
        first.markComplete(.addCamera)

        // Relaunch on the same version reuses the persisted store.
        let relaunch = SetupStateStore(defaults: defaults, version: "1.0 (1)")
        XCTAssertFalse(relaunch.resetForVersionChangeIfNeeded(), "same version must not reset")
        XCTAssertNil(relaunch.launchStep(), "completion must be preserved within a version")
    }

    func testStoreNewVersionClearsCompletionAndReopensAtCamera() throws {
        let defaults = try freshDefaults("newVersion")
        let old = SetupStateStore(defaults: defaults, version: "1.0 (1)")
        old.resetForVersionChangeIfNeeded()
        old.markComplete(.camera)
        old.markComplete(.microphone)
        old.markComplete(.addCamera)
        XCTAssertNil(old.launchStep(), "complete under the old version")

        // Update to a new marketing version: the next launch must clear and restart.
        let updated = SetupStateStore(defaults: defaults, version: "1.1 (2)")
        XCTAssertTrue(updated.resetForVersionChangeIfNeeded(), "a version change must reset")
        XCTAssertFalse(updated.isComplete(.camera))
        XCTAssertFalse(updated.isComplete(.microphone))
        XCTAssertFalse(updated.isComplete(.addCamera))
        XCTAssertEqual(updated.launchStep(), .camera)
    }

    func testStoreNewBuildNumberClearsCompletion() throws {
        let defaults = try freshDefaults("newBuild")
        let old = SetupStateStore(defaults: defaults, version: "1.0 (1)")
        old.resetForVersionChangeIfNeeded()
        old.markComplete(.camera)

        // Only the build number changed; that is still a new version identity.
        let updated = SetupStateStore(defaults: defaults, version: "1.0 (2)")
        XCTAssertTrue(updated.resetForVersionChangeIfNeeded())
        XCTAssertEqual(updated.launchStep(), .camera)
    }

    /// An isolated, empty `UserDefaults` suite for a single test.
    private func freshDefaults(_ name: String) throws -> UserDefaults {
        let suite = "SetupStateStoreTests.\(name)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}

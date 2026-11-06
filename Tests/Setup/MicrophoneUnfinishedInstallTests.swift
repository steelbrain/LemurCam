@testable import LemurCam
import XCTest

/// "Skip for Now" (or Re-check Now) after the helper reported an install failed, such
/// as "Driver installed but coreaudiod restart failed", let the failure go, and the
/// next check found the copy in place and showed Ready, with Settings offering only
/// Remove, though coreaudiod never loaded it. The install is now remembered as
/// unfinished, and Update stays offered until an install or removal succeeds.
/// Against a fake helper.
@MainActor
internal final class MicrophoneUnfinishedInstallTests: XCTestCase {
    private var fixture: SetupCoordinatorFixture?
    private let restartFailed = "Driver installed but coreaudiod restart failed: coreaudiod did not restart"

    override func setUp() async throws {
        try await super.setUp()
        fixture = try SetupCoordinatorFixture(operationTimeLimit: .milliseconds(100))
    }

    override func tearDown() async throws {
        fixture?.cleanUp()
        fixture = nil
        try await super.tearDown()
    }

    func testSkippingAFailedInstallOffersUpdate() async throws {
        let harness = try XCTUnwrap(fixture)
        let failed = await harness.install(answering: .failed(restartFailed))
        XCTAssertTrue(failed)

        harness.coordinator.acknowledgeMicrophoneFailure()
        harness.helper.answerCheck("6")
        let ready = await waitUntil { harness.coordinator.micStatus == .ready }

        XCTAssertTrue(ready)
        XCTAssertEqual(harness.coordinator.microphoneUpdateReason, .unfinishedInstall)
        XCTAssertTrue(harness.coordinator.microphoneNeedsUpdate)
        XCTAssertEqual(harness.helper.installs.count, 1, "nothing is redone by itself")
    }

    func testRecheckingAFailedInstallOffersUpdate() async throws {
        let harness = try XCTUnwrap(fixture)
        let failed = await harness.install(answering: .failed(restartFailed))
        XCTAssertTrue(failed)

        harness.coordinator.recheckMicrophone()
        harness.helper.answerCheck("6")
        let ready = await waitUntil { harness.coordinator.micStatus == .ready }

        XCTAssertTrue(ready)
        XCTAssertEqual(harness.coordinator.microphoneUpdateReason, .unfinishedInstall)
    }

    /// Update installs again; once that succeeds the microphone is just Ready.
    func testASuccessfulUpdateEndsIt() async throws {
        let harness = try XCTUnwrap(fixture)
        let failed = await harness.install(answering: .failed(restartFailed))
        XCTAssertTrue(failed)
        harness.coordinator.acknowledgeMicrophoneFailure()
        harness.helper.answerCheck("6")
        let ready = await waitUntil { harness.coordinator.microphoneUpdateReason == .unfinishedInstall }
        XCTAssertTrue(ready)

        harness.coordinator.updateMicrophone()
        XCTAssertEqual(harness.helper.installs.count, 2)
        try XCTUnwrap(harness.helper.installs.last)(.succeeded)
        let verifying = await waitUntil { harness.helper.checks.count == 2 }
        XCTAssertTrue(verifying)
        harness.helper.answerCheck("6")
        let updated = await waitUntil {
            harness.coordinator.micStatus == .ready && harness.coordinator.microphoneUpdateReason == nil
        }
        XCTAssertTrue(updated)
    }

    /// A check finding no driver has nothing left to restart for.
    func testNoDriverEndsIt() async throws {
        let harness = try XCTUnwrap(fixture)
        let failed = await harness.install(answering: .failed("Failed to install driver: copy failed"))
        XCTAssertTrue(failed)
        harness.coordinator.acknowledgeMicrophoneFailure()
        harness.helper.answerCheck(nil)
        let notSetUp = await waitUntil { harness.coordinator.micStatus == .notSetUp }
        XCTAssertTrue(notSetUp)

        // A driver installed later (by another app copy, say) is not called unfinished.
        harness.coordinator.refreshMicrophoneStatus()
        harness.helper.answerCheck("6")
        let ready = await waitUntil { harness.coordinator.micStatus == .ready }
        XCTAssertTrue(ready)
        XCTAssertNil(harness.coordinator.microphoneUpdateReason)
    }

    /// An install the helper never answered may have finished: Skip shows what the
    /// check finds, as before.
    func testSkippingAnInstallTheHelperNeverAnsweredOffersNothingMore() async throws {
        let harness = try XCTUnwrap(fixture)
        let failed = await harness.install(answering: .noAnswer("Helper unavailable: connection interrupted"))
        XCTAssertTrue(failed)

        harness.coordinator.acknowledgeMicrophoneFailure()
        harness.helper.answerCheck("6")
        let ready = await waitUntil { harness.coordinator.micStatus == .ready }

        XCTAssertTrue(ready)
        XCTAssertNil(harness.coordinator.microphoneUpdateReason)
    }

    func testSkippingAFailedRemovalOffersNothingMore() async throws {
        let harness = try XCTUnwrap(fixture)
        harness.coordinator.disableMicrophone()
        try XCTUnwrap(harness.helper.removals.last)(.failed("Failed to remove driver: busy"))
        let failed = await waitUntil {
            if case .failed = harness.coordinator.micStatus { return true }
            return false
        }
        XCTAssertTrue(failed)

        harness.coordinator.acknowledgeMicrophoneFailure()
        harness.helper.answerCheck("6")
        let ready = await waitUntil { harness.coordinator.micStatus == .ready }

        XCTAssertTrue(ready)
        XCTAssertNil(harness.coordinator.microphoneUpdateReason)
    }

    func testTheReasonAndItsCopy() {
        XCTAssertEqual(
            MicrophoneUpdateReason.reason(installed: "6", bundled: "6", sealed: true, installUnfinished: true),
            .unfinishedInstall
        )
        XCTAssertEqual(
            MicrophoneUpdateReason.reason(installed: "6", bundled: "6", sealed: false, installUnfinished: true),
            .unfinishedInstall
        )
        XCTAssertNil(MicrophoneUpdateReason.reason(installed: nil, bundled: "6", sealed: true, installUnfinished: true))
        XCTAssertEqual(MicrophoneStatusCopy.update(.unfinishedInstall), MicrophoneStatusCopy.unfinishedInstall)
    }
}

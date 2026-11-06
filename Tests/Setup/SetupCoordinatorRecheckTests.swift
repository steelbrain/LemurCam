@testable import LemurCam
import XCTest

/// "Re-check Now" in Settings ran the same refresh as the app's own polls, which
/// keep a failed install's reason up until the user acts, so with a failure showing
/// it changed nothing visible. It is the user acting: it now lets the failure go and
/// shows what the check finds, without redoing anything. Against a fake helper.
@MainActor
internal final class SetupCoordinatorRecheckTests: XCTestCase {
    private var fixture: SetupCoordinatorFixture?
    private let message = "Driver installed but coreaudiod restart failed: coreaudiod did not come back"

    override func setUp() async throws {
        try await super.setUp()
        fixture = try SetupCoordinatorFixture(checkTimeLimit: .milliseconds(200))
    }

    override func tearDown() async throws {
        fixture?.cleanUp()
        fixture = nil
        try await super.tearDown()
    }

    func testRecheckReplacesAHeldFailureWithWhatTheCheckFinds() async throws {
        let harness = try XCTUnwrap(fixture)
        let failed = await harness.install(answering: .failed(message))
        XCTAssertTrue(failed)

        harness.coordinator.recheckMicrophone()
        XCTAssertEqual(harness.coordinator.micStatus, .unknown, "the check shows as running")
        XCTAssertEqual(harness.helper.checks.count, 1)
        harness.helper.answerCheck("6")
        let ready = await waitUntil { harness.coordinator.micStatus == .ready }

        XCTAssertTrue(ready)
        XCTAssertEqual(harness.helper.installs.count, 1, "a re-check redoes nothing")
    }

    func testRecheckShowsAHelperThatNeedsApprovalAgain() async throws {
        let harness = try XCTUnwrap(fixture)
        let failed = await harness.install(answering: .failed(message))
        XCTAssertTrue(failed)
        harness.helper.state = .requiresApproval

        harness.coordinator.recheckMicrophone()

        XCTAssertEqual(harness.coordinator.micStatus, .needsApproval)
        XCTAssertTrue(harness.helper.checks.isEmpty)
    }

    /// The reason does not survive a helper that does not answer the check either.
    func testRecheckShowsAnUnreachableHelper() async throws {
        let harness = try XCTUnwrap(fixture)
        let failed = await harness.install(answering: .failed(message))
        XCTAssertTrue(failed)

        harness.coordinator.recheckMicrophone()
        let unreachable = await waitUntil {
            harness.coordinator.micStatus == .failed(MicrophoneVersionReply.unreachableMessage)
        }

        XCTAssertTrue(unreachable)
    }

    /// Try Again is unchanged: a failure the helper reported is still redone, also
    /// after routine refreshes, which still keep it up.
    func testRoutineRefreshesStillHoldTheFailureForTryAgain() async throws {
        let harness = try XCTUnwrap(fixture)
        let failed = await harness.install(answering: .failed(message))
        XCTAssertTrue(failed)

        harness.coordinator.refreshMicrophoneStatus()
        harness.helper.answerCheck("6")
        let applied = await waitUntil { harness.coordinator.installedDriverVersion == "6" }
        XCTAssertTrue(applied)
        XCTAssertEqual(harness.coordinator.micStatus, .failed(message))

        harness.coordinator.retryMicrophone()
        XCTAssertEqual(harness.helper.installs.count, 2, "redone, not checked")
    }

    func testRecheckWithNothingHeldIsARoutineRefresh() async throws {
        let harness = try XCTUnwrap(fixture)
        let ready = await harness.makeReady()
        XCTAssertTrue(ready)

        harness.coordinator.recheckMicrophone()

        XCTAssertEqual(harness.coordinator.micStatus, .ready, "no Working… flash over a working microphone")
        XCTAssertEqual(harness.helper.checks.count, 2)
    }

    func testRecheckLeavesARunningOperationAlone() throws {
        let harness = try XCTUnwrap(fixture)
        harness.coordinator.updateMicrophone()

        harness.coordinator.recheckMicrophone()

        XCTAssertEqual(harness.coordinator.micStatus, .installing)
        XCTAssertTrue(harness.helper.checks.isEmpty)
    }
}

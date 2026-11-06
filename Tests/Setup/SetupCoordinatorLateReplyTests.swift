@testable import LemurCam
import XCTest

/// A microphone install or removal the helper does not answer in time is failed, and
/// the user can start another. The first one's reply could still arrive while the
/// second ran, and it ended the second: it cleared the in-progress flag, cancelled
/// the second's time limit and put up its own result. Each operation now carries a
/// token, and only the current operation's reply or time-out applies.
@MainActor
internal final class SetupCoordinatorLateReplyTests: XCTestCase {
    private static let noReply = "The microphone helper didn’t respond. Please try again."

    private var fixture: SetupCoordinatorFixture?

    override func setUp() async throws {
        try await super.setUp()
        fixture = try SetupCoordinatorFixture(operationTimeLimit: .milliseconds(300))
    }

    override func tearDown() async throws {
        fixture?.cleanUp()
        fixture = nil
        try await super.tearDown()
    }

    /// Start an install the helper never answers and wait for its time limit.
    private func installThatTimesOut(
        in harness: SetupCoordinatorFixture
    ) async throws -> (MicrophoneOperationResult) -> Void {
        harness.coordinator.updateMicrophone()
        let reply = try XCTUnwrap(harness.helper.installs.last)
        let timedOut = await waitUntil { harness.coordinator.micStatus == .failed(Self.noReply) }
        XCTAssertTrue(timedOut)
        return reply
    }

    func testALateSuccessDoesNotEndTheNewerOperation() async throws {
        let harness = try XCTUnwrap(fixture)
        let lateReply = try await installThatTimesOut(in: harness)
        harness.coordinator.disableMicrophone()
        XCTAssertEqual(harness.coordinator.micStatus, .installing)

        lateReply(.succeeded)
        let ended = await waitUntil(timeout: 0.1) { harness.coordinator.micStatus != .installing }

        XCTAssertFalse(ended, "the removal is still running")
        XCTAssertTrue(harness.helper.checks.isEmpty, "the late reply must not start a check")
        try XCTUnwrap(harness.helper.removals.last)(.succeeded)
        let checking = await waitUntil { harness.helper.checks.count == 1 }
        XCTAssertTrue(checking, "the removal's own reply still applies")
        harness.helper.answerCheck(nil)
        let notSetUp = await waitUntil { harness.coordinator.micStatus == .notSetUp }
        XCTAssertTrue(notSetUp)
    }

    func testALateFailureDoesNotEndTheNewerOperationNorStopItsTimeLimit() async throws {
        let harness = try XCTUnwrap(fixture)
        let lateReply = try await installThatTimesOut(in: harness)
        harness.coordinator.updateMicrophone()
        XCTAssertEqual(harness.helper.installs.count, 2)

        lateReply(.failed("Driver installation failed: first attempt"))
        let ended = await waitUntil(timeout: 0.1) { harness.coordinator.micStatus != .installing }
        XCTAssertFalse(ended, "the second install is still running")

        // The second install is never answered either: its own time limit ends it.
        let timedOut = await waitUntil { harness.coordinator.micStatus == .failed(Self.noReply) }
        XCTAssertTrue(timedOut)
    }

    /// With nothing newer started, a reply that came too late still replaces the
    /// "didn't respond" failure.
    func testALateReplyStillAppliesWhenNothingNewerStarted() async throws {
        let harness = try XCTUnwrap(fixture)
        let lateReply = try await installThatTimesOut(in: harness)

        let message = "Driver installation failed: disk full"
        lateReply(.failed(message))
        let shown = await waitUntil { harness.coordinator.micStatus == .failed(message) }

        XCTAssertTrue(shown)
    }
}

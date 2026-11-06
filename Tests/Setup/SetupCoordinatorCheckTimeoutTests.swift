@testable import LemurCam
import XCTest

/// An installed-driver check the helper accepts but never answers must time out even
/// while the setup window keeps refreshing (every 2.5 s in the app). Each refresh
/// used to send a new check and restart the time limit, so it never ran out and the
/// spinner (after Try Again, or while verifying an install) stayed up for good.
@MainActor
internal final class SetupCoordinatorCheckTimeoutTests: XCTestCase {
    private var fixture: SetupCoordinatorFixture?
    private let unreachable = MicrophoneStatus.failed(MicrophoneVersionReply.unreachableMessage)

    override func setUp() async throws {
        try await super.setUp()
        fixture = try SetupCoordinatorFixture(checkTimeLimit: .milliseconds(300))
    }

    override func tearDown() async throws {
        fixture?.cleanUp()
        fixture = nil
        try await super.tearDown()
    }

    /// Refresh every 50 ms, much faster than the time limit, until `condition` holds.
    private func refreshRepeatedly(_ harness: SetupCoordinatorFixture, until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while !condition() {
            if Date() >= deadline { return false }
            harness.coordinator.refreshMicrophoneStatus()
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    func testTryAgainWithAHelperThatNeverAnswersFailsDespiteRefreshes() async throws {
        let harness = try XCTUnwrap(fixture)
        harness.coordinator.retryMicrophone()
        XCTAssertEqual(harness.coordinator.micStatus, .unknown)

        let failed = await refreshRepeatedly(harness) { harness.coordinator.micStatus == unreachable }
        XCTAssertTrue(failed, "the spinner must give way to Try Again")
        XCTAssertEqual(harness.helper.checks.count, 1, "refreshes wait for the check already sent")
    }

    func testVerifyingAnInstallWithAHelperThatNeverAnswersFailsDespiteRefreshes() async throws {
        let harness = try XCTUnwrap(fixture)
        harness.coordinator.updateMicrophone()
        try XCTUnwrap(harness.helper.installs.last)(.succeeded)
        let checking = await waitUntil { harness.helper.checks.count == 1 }
        XCTAssertTrue(checking)
        XCTAssertEqual(harness.coordinator.micStatus, .installing)

        let failed = await refreshRepeatedly(harness) { harness.coordinator.micStatus == unreachable }
        XCTAssertTrue(failed)
        XCTAssertEqual(harness.helper.checks.count, 1)
    }

    func testTheNextRefreshAfterTheTimeLimitSendsANewCheck() async throws {
        let harness = try XCTUnwrap(fixture)
        harness.coordinator.retryMicrophone()
        let failed = await waitUntil { harness.coordinator.micStatus == unreachable }
        XCTAssertTrue(failed)

        harness.coordinator.refreshMicrophoneStatus()
        XCTAssertEqual(harness.helper.checks.count, 2)
        harness.helper.answerCheck("6")
        let ready = await waitUntil { harness.coordinator.micStatus == .ready }
        XCTAssertTrue(ready, "a helper that answers again recovers the status")
    }

    func testNoCheckIsSentWhileAnInstallRuns() async throws {
        let harness = try XCTUnwrap(fixture)
        harness.coordinator.updateMicrophone()
        for _ in 0..<3 { harness.coordinator.refreshMicrophoneStatus() }
        XCTAssertTrue(harness.helper.checks.isEmpty, "the helper would answer only after the install")

        try XCTUnwrap(harness.helper.installs.last)(.succeeded)
        let checking = await waitUntil { harness.helper.checks.count == 1 }
        XCTAssertTrue(checking, "the install is verified by a check of its own")
    }

    func testACheckSentBeforeAnInstallDoesNotAnswerForAfterIt() async throws {
        let harness = try XCTUnwrap(fixture)
        harness.coordinator.refreshMicrophoneStatus()
        let before = try XCTUnwrap(harness.helper.checks.first)

        harness.coordinator.updateMicrophone()
        try XCTUnwrap(harness.helper.installs.last)(.succeeded)
        let checking = await waitUntil { harness.helper.checks.count == 2 }
        XCTAssertTrue(checking, "the install is verified by a check of its own")

        // The earlier check saw the copy from before the install: unsealed. Taken as
        // the verification, it would claim a stale helper and ask for a restart.
        before(InstalledDriverCheck(reachable: true, version: "5", sealed: false))
        harness.helper.answerCheck("6")
        let ready = await waitUntil { harness.coordinator.micStatus == .ready }
        XCTAssertTrue(ready)
        XCTAssertEqual(harness.coordinator.installedDriverVersion, "6")
    }
}

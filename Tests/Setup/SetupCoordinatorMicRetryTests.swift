@testable import LemurCam
import XCTest

/// "Try Again" through the coordinator, against a fake helper. When the helper itself
/// answered that an install or removal failed ("Driver installed but coreaudiod
/// restart failed"), the files can be in place with coreaudiod never restarted, so
/// a check would find the bundled driver and wrongly show Ready: Try Again redoes
/// the operation. Only when the helper never answered does it check first.
@MainActor
internal final class SetupCoordinatorMicRetryTests: XCTestCase {
    private var fixture: SetupCoordinatorFixture?

    override func setUp() async throws {
        try await super.setUp()
        fixture = try SetupCoordinatorFixture(operationTimeLimit: .milliseconds(100))
    }

    override func tearDown() async throws {
        fixture?.cleanUp()
        fixture = nil
        try await super.tearDown()
    }

    func testTryAgainRedoesAnInstallTheHelperReportedAsFailed() async throws {
        let harness = try XCTUnwrap(fixture)
        let message = "Driver installed but coreaudiod restart failed: coreaudiod did not come back"
        let failed = await harness.install(answering: .failed(message))
        XCTAssertTrue(failed)
        XCTAssertEqual(harness.coordinator.micStatus, .failed(message))

        harness.coordinator.retryMicrophone()
        XCTAssertEqual(harness.helper.installs.count, 2, "redone, not checked")
        XCTAssertTrue(harness.helper.checks.isEmpty)
        XCTAssertEqual(harness.coordinator.micStatus, .installing)
    }

    func testTryAgainRedoesARemovalTheHelperReportedAsFailed() async throws {
        let harness = try XCTUnwrap(fixture)
        harness.coordinator.disableMicrophone()
        let message = "Driver removed but coreaudiod restart failed: coreaudiod did not come back"
        try XCTUnwrap(harness.helper.removals.last)(.failed(message))
        let failed = await waitUntil { harness.coordinator.micStatus == .failed(message) }
        XCTAssertTrue(failed)

        harness.coordinator.retryMicrophone()
        XCTAssertEqual(harness.helper.removals.count, 2, "redone, not checked")
        XCTAssertTrue(harness.helper.checks.isEmpty)
    }

    func testTryAgainAfterAnUnreachableHelperChecksFirst() async throws {
        let harness = try XCTUnwrap(fixture)
        let failed = await harness.install(answering: .noAnswer("Helper unavailable: connection interrupted"))
        XCTAssertTrue(failed)

        harness.coordinator.retryMicrophone()
        XCTAssertEqual(harness.helper.checks.count, 1)
        XCTAssertEqual(harness.helper.installs.count, 1)
        XCTAssertEqual(harness.coordinator.micStatus, .unknown)

        // It had worked: no second install, so no second coreaudiod restart.
        harness.helper.answerCheck("6")
        let ready = await waitUntil { harness.coordinator.micStatus == .ready }
        XCTAssertTrue(ready)
        XCTAssertEqual(harness.helper.installs.count, 1)
    }

    func testTryAgainAfterAnUnreachableHelperInstallsWhenTheCheckFindsItStillNeeded() async throws {
        let harness = try XCTUnwrap(fixture)
        let failed = await harness.install(answering: .noAnswer("Helper unavailable: connection interrupted"))
        XCTAssertTrue(failed)

        harness.coordinator.retryMicrophone()
        harness.helper.answerCheck(nil)
        let reinstalling = await waitUntil { harness.helper.installs.count == 2 }
        XCTAssertTrue(reinstalling)
    }

    func testTryAgainAfterAnInstallTheHelperNeverAnsweredChecksFirst() async throws {
        let harness = try XCTUnwrap(fixture)
        harness.coordinator.updateMicrophone()
        let timedOut = await waitUntil {
            if case .failed = harness.coordinator.micStatus { return true }
            return false
        }
        XCTAssertTrue(timedOut, "an install with no reply fails after the time limit")

        harness.coordinator.retryMicrophone()
        XCTAssertEqual(harness.helper.checks.count, 1)
        XCTAssertEqual(harness.helper.installs.count, 1)
    }

    func testALateSuccessReplacesTheNoReplyFailure() async throws {
        let harness = try XCTUnwrap(fixture)
        harness.coordinator.updateMicrophone()
        let timedOut = await waitUntil { harness.coordinator.micStatus != .installing }
        XCTAssertTrue(timedOut)

        try XCTUnwrap(harness.helper.installs.last)(.succeeded)
        let checking = await waitUntil { harness.helper.checks.count == 1 }
        XCTAssertTrue(checking, "the late reply is verified like any install")
        harness.helper.answerCheck("6")
        let ready = await waitUntil { harness.coordinator.micStatus == .ready }
        XCTAssertTrue(ready)
    }
}

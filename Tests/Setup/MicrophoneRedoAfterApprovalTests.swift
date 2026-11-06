@testable import LemurCam
import XCTest

/// A failed install's or removal's reason stays up while the helper is not approved
/// (the user turned it off in Login Items, say). Try Again then went through Enable,
/// which forgot the failed operation and set up an automatic install: after a failed
/// removal and re-approval, the check found no driver and installed the microphone
/// the user had removed; after a failed install (coreaudiod not restarted) it found
/// the copy in place and showed Ready with nothing redone. Try Again now only
/// registers the helper or opens Login Items, and the first check after approval
/// redoes exactly the operation that failed. Against a fake helper.
@MainActor
internal final class MicrophoneRedoAfterApprovalTests: XCTestCase {
    private var fixture: SetupCoordinatorFixture?
    private let removeFailed = "Driver removed but coreaudiod restart failed: coreaudiod did not restart"
    private let installFailed = "Driver installed but coreaudiod restart failed: coreaudiod did not restart"

    override func setUp() async throws {
        try await super.setUp()
        fixture = try SetupCoordinatorFixture(operationTimeLimit: .milliseconds(100))
    }

    override func tearDown() async throws {
        fixture?.cleanUp()
        fixture = nil
        try await super.tearDown()
    }

    /// A removal answered with `result`, then the helper's approval taken away.
    private func failRemoval(_ harness: SetupCoordinatorFixture, with result: MicrophoneOperationResult) async -> Bool {
        guard await harness.makeReady() else { return false }
        harness.coordinator.disableMicrophone()
        harness.helper.removals.last?(result)
        let failed = await waitUntil {
            if case .failed = harness.coordinator.micStatus { return true }
            return false
        }
        harness.helper.state = .requiresApproval
        harness.coordinator.refreshMicrophoneStatus()
        return failed
    }

    /// The helper approved again, and the setup window's next poll.
    private func approve(_ harness: SetupCoordinatorFixture) -> Int {
        harness.helper.state = .enabled
        harness.coordinator.refreshMicrophoneStatus()
        return harness.helper.checks.count
    }

    // MARK: - The reported cases

    func testARemovalRedoneAfterReapprovalNeverInstalls() async throws {
        let harness = try XCTUnwrap(fixture)
        let failed = await failRemoval(harness, with: .failed(removeFailed))
        XCTAssertTrue(failed)
        XCTAssertEqual(harness.coordinator.micStatus, .failed(removeFailed), "held while not approved")

        harness.coordinator.retryMicrophone()
        XCTAssertEqual(harness.coordinator.micStatus, .needsApproval)
        XCTAssertEqual(harness.helper.loginItemsOpened, 1)
        XCTAssertEqual(harness.helper.removals.count, 1)

        let checks = approve(harness)
        harness.helper.answerCheck(nil)
        let redone = await waitUntil { harness.helper.removals.count == 2 }
        XCTAssertTrue(redone, "the removal is redone, restarting coreaudiod")
        XCTAssertTrue(harness.helper.installs.isEmpty)

        try XCTUnwrap(harness.helper.removals.last)(.succeeded)
        let checked = await waitUntil { harness.helper.checks.count == checks + 1 }
        XCTAssertTrue(checked)
        harness.helper.answerCheck(nil)
        let removed = await waitUntil { harness.coordinator.micStatus == .notSetUp }
        XCTAssertTrue(removed)
        XCTAssertTrue(harness.helper.installs.isEmpty, "the removed microphone is not installed back")
    }

    func testAnInstallRedoneAfterReapprovalEvenWhenTheCopyIsInPlace() async throws {
        let harness = try XCTUnwrap(fixture)
        let failed = await harness.install(answering: .failed(installFailed))
        XCTAssertTrue(failed)
        harness.helper.state = .requiresApproval

        harness.coordinator.retryMicrophone()
        XCTAssertEqual(harness.coordinator.micStatus, .needsApproval)
        XCTAssertEqual(harness.helper.installs.count, 1)

        _ = approve(harness)
        harness.helper.answerCheck("6")
        let redone = await waitUntil { harness.helper.installs.count == 2 }
        XCTAssertTrue(redone, "a copy in place is not proof coreaudiod loaded it")
    }

    // MARK: - Details

    /// A removal the helper never answered may have finished: the check after
    /// approval redoes it only while the driver is still installed, and never installs.
    func testAnUnansweredRemovalIsCheckedAfterReapproval() async throws {
        let harness = try XCTUnwrap(fixture)
        let failed = await failRemoval(harness, with: .noAnswer("Helper unavailable: connection interrupted"))
        XCTAssertTrue(failed)
        harness.coordinator.retryMicrophone()

        _ = approve(harness)
        harness.helper.answerCheck(nil)
        let notSetUp = await waitUntil { harness.coordinator.micStatus == .notSetUp }
        XCTAssertTrue(notSetUp)
        XCTAssertEqual(harness.helper.removals.count, 1, "it had worked")
        XCTAssertTrue(harness.helper.installs.isEmpty)
    }

    func testAnUnansweredRemovalOfADriverStillThereIsRedone() async throws {
        let harness = try XCTUnwrap(fixture)
        let failed = await failRemoval(harness, with: .noAnswer("Helper unavailable: connection interrupted"))
        XCTAssertTrue(failed)
        harness.coordinator.retryMicrophone()

        _ = approve(harness)
        harness.helper.answerCheck("6")
        let redone = await waitUntil { harness.helper.removals.count == 2 }
        XCTAssertTrue(redone)
    }

    /// A helper no longer registered is registered again; nothing else runs.
    func testAnUnregisteredHelperIsRegisteredAgain() async throws {
        let harness = try XCTUnwrap(fixture)
        let failed = await failRemoval(harness, with: .failed(removeFailed))
        XCTAssertTrue(failed)
        harness.helper.state = .notRegistered

        harness.coordinator.retryMicrophone()

        XCTAssertEqual(harness.helper.registrations, 1)
        XCTAssertEqual(harness.coordinator.micStatus, .needsApproval)
        XCTAssertEqual(harness.helper.removals.count, 1)
        XCTAssertTrue(harness.helper.installs.isEmpty)
    }

    /// A first check after approval that can't reach the helper redoes nothing yet;
    /// the next one that does still redoes the removal.
    func testTheRedoWaitsForACheckThatReachesTheHelper() async throws {
        let harness = try XCTUnwrap(fixture)
        let failed = await failRemoval(harness, with: .failed(removeFailed))
        XCTAssertTrue(failed)
        harness.coordinator.retryMicrophone()

        let checks = approve(harness)
        harness.helper.checks.last?(.unreachable)
        // The setup window's polls: the next one after the reply lands sends a check.
        let checking = await waitUntil {
            harness.coordinator.refreshMicrophoneStatus()
            return harness.helper.checks.count == checks + 1
        }
        XCTAssertTrue(checking)
        XCTAssertEqual(harness.coordinator.micStatus, .needsApproval, "a known status survives")
        XCTAssertEqual(harness.helper.removals.count, 1)
        harness.helper.answerCheck(nil)
        let redone = await waitUntil { harness.helper.removals.count == 2 }
        XCTAssertTrue(redone)
        XCTAssertTrue(harness.helper.installs.isEmpty)
    }

    /// Enable is a new start: it replaces the redo with the usual automatic install.
    func testEnableReplacesTheRedo() async throws {
        let harness = try XCTUnwrap(fixture)
        let failed = await failRemoval(harness, with: .failed(removeFailed))
        XCTAssertTrue(failed)
        harness.coordinator.retryMicrophone()

        harness.coordinator.enableMicrophone()
        _ = approve(harness)
        harness.helper.answerCheck(nil)
        let installing = await waitUntil { harness.helper.installs.count == 1 }
        XCTAssertTrue(installing)
        XCTAssertEqual(harness.helper.removals.count, 1)
    }

    // MARK: - The decision

    func testTheFirstCheckAfterApprovalRedoesTheOperation() {
        func decide(_ version: String?, _ failure: MicrophoneOperationFailure) -> MicrophoneVersionReply {
            MicrophoneVersionReply.decide(
                InstalledDriverCheck(reachable: true, version: version, sealed: true),
                context: MicrophoneCheckContext(
                    currentStatus: .needsApproval, autoInstallPending: true, bundledVersion: "6",
                    redoAfterApproval: failure
                )
            )
        }
        let reportedRemoval = MicrophoneOperationFailure(operation: .remove, reportedByHelper: true)
        let reportedInstall = MicrophoneOperationFailure(operation: .install, reportedByHelper: true)
        let unansweredRemoval = MicrophoneOperationFailure(operation: .remove, reportedByHelper: false)
        let unansweredInstall = MicrophoneOperationFailure(operation: .install, reportedByHelper: false)

        XCTAssertEqual(decide(nil, reportedRemoval), .uninstallDriver)
        XCTAssertEqual(decide("6", reportedRemoval), .uninstallDriver)
        XCTAssertEqual(decide("6", reportedInstall), .installDriver)
        XCTAssertEqual(decide(nil, unansweredRemoval), .setStatus(.notSetUp), "never installs for a removal")
        XCTAssertEqual(decide("6", unansweredRemoval), .uninstallDriver)
        XCTAssertEqual(decide("6", unansweredInstall), .setStatus(.ready))
        XCTAssertEqual(decide(nil, unansweredInstall), .installDriver)
    }
}

@testable import LemurCam
import XCTest

/// A failed install's reason stays up through the setup window's routine refreshes
/// until the user acts on it, against a fake helper. The refreshes still read the
/// installed version and seal behind it.
@MainActor
internal final class SetupCoordinatorFailureHoldTests: XCTestCase {
    private var fixture: SetupCoordinatorFixture?
    private let message = "Driver installed but coreaudiod restart failed: coreaudiod did not come back"

    override func setUp() async throws {
        try await super.setUp()
        fixture = try SetupCoordinatorFixture()
    }

    override func tearDown() async throws {
        fixture?.cleanUp()
        fixture = nil
        try await super.tearDown()
    }

    func testRoutineRefreshesKeepTheFailureAndUpdateTheInstalledState() async throws {
        let harness = try XCTUnwrap(fixture)
        let failed = await harness.install(answering: .failed(message))
        XCTAssertTrue(failed)

        // The setup window's polls: each check reaches the helper and is answered.
        for version in ["6", "7", "8"] {
            harness.coordinator.refreshMicrophoneStatus()
            harness.helper.answerCheck(version, sealed: false)
            let applied = await waitUntil { harness.coordinator.installedDriverVersion == version }
            XCTAssertTrue(applied, "the check still applies behind the failure")
            XCTAssertEqual(harness.coordinator.micStatus, .failed(message))
        }
        XCTAssertEqual(harness.helper.checks.count, 3)
        XCTAssertFalse(harness.coordinator.installedDriverSealed)
        XCTAssertEqual(harness.helper.installs.count, 1, "a routine check never starts an install")
    }

    func testAFailureIsKeptWhileTheHelperIsNoLongerApproved() async throws {
        let harness = try XCTUnwrap(fixture)
        let failed = await harness.install(answering: .failed(message))
        XCTAssertTrue(failed)

        harness.helper.state = .requiresApproval
        harness.coordinator.refreshMicrophoneStatus()
        XCTAssertEqual(harness.coordinator.micStatus, .failed(message))
    }

    func testMovingPastTheStepReleasesTheFailure() async throws {
        let harness = try XCTUnwrap(fixture)
        let failed = await harness.install(answering: .failed(message))
        XCTAssertTrue(failed)

        harness.coordinator.acknowledgeMicrophoneFailure()
        harness.helper.answerCheck("6")
        let ready = await waitUntil { harness.coordinator.micStatus == .ready }
        XCTAssertTrue(ready)
        XCTAssertEqual(harness.helper.installs.count, 1)
    }

    func testAcknowledgingWithNoFailureChangesNothing() async throws {
        let harness = try XCTUnwrap(fixture)
        let ready = await harness.makeReady()
        XCTAssertTrue(ready)
        harness.coordinator.acknowledgeMicrophoneFailure()
        XCTAssertEqual(harness.helper.checks.count, 1, "no extra check")
        XCTAssertEqual(harness.coordinator.micStatus, .ready)
    }
}

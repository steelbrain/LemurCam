import Foundation
@testable import LemurCam
import XCTest

/// Why registering the microphone helper failed stays up until the user acts on it,
/// against a fake helper. It was not held: the setup window's next poll (every
/// 2.5 s), or the app becoming active, found the helper still not registered and
/// showed "Not set up" with Enable again, so the reason was gone before it was read.
@MainActor
internal final class SetupCoordinatorRegistrationFailureTests: XCTestCase {
    private var fixture: SetupCoordinatorFixture?
    private let failed = MicrophoneStatus.failed("Couldn’t register the audio helper: Operation not permitted")

    override func setUp() async throws {
        try await super.setUp()
        let harness = try SetupCoordinatorFixture()
        harness.helper.state = .notRegistered
        harness.helper.registrationError = NSError(
            domain: "SMAppServiceErrorDomain", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Operation not permitted"]
        )
        fixture = harness
    }

    override func tearDown() async throws {
        fixture?.cleanUp()
        fixture = nil
        try await super.tearDown()
    }

    /// Enable, and let registering the helper fail.
    private func failRegistration() throws -> SetupCoordinatorFixture {
        let harness = try XCTUnwrap(fixture)
        harness.coordinator.enableMicrophone()
        XCTAssertEqual(harness.coordinator.micStatus, failed)
        return harness
    }

    func testRoutineRefreshesKeepTheReasonWhileTheHelperIsNotRegistered() throws {
        let harness = try failRegistration()

        // The setup window's polls and app activations.
        for state: AudioDeviceInstaller.State in [.notRegistered, .notFound, .notRegistered] {
            harness.helper.state = state
            harness.coordinator.refreshMicrophoneStatus()
            XCTAssertEqual(harness.coordinator.micStatus, failed, "\(state)")
        }
        XCTAssertEqual(harness.helper.registrations, 1, "a routine refresh never registers")
    }

    func testTryAgainRegistersAgain() throws {
        let harness = try failRegistration()
        harness.coordinator.refreshMicrophoneStatus()

        harness.helper.registrationError = nil
        harness.coordinator.retryMicrophone()

        XCTAssertEqual(harness.helper.registrations, 2)
        XCTAssertEqual(harness.coordinator.micStatus, .needsApproval)
    }

    func testARegistrationThatFailsAgainIsHeldAgain() throws {
        let harness = try failRegistration()

        harness.coordinator.retryMicrophone()
        harness.coordinator.refreshMicrophoneStatus()

        XCTAssertEqual(harness.helper.registrations, 2)
        XCTAssertEqual(harness.coordinator.micStatus, failed)
    }

    func testMovingPastTheStepReleasesTheReason() throws {
        let harness = try failRegistration()

        harness.coordinator.acknowledgeMicrophoneFailure()
        XCTAssertEqual(harness.coordinator.micStatus, .notSetUp)
        harness.coordinator.refreshMicrophoneStatus()
        XCTAssertEqual(harness.coordinator.micStatus, .notSetUp)
        XCTAssertEqual(harness.helper.registrations, 1, "Skip registers nothing")
    }

    func testRecheckReleasesTheReason() throws {
        let harness = try failRegistration()

        harness.coordinator.recheckMicrophone()

        XCTAssertEqual(harness.coordinator.micStatus, .notSetUp)
        XCTAssertEqual(harness.helper.registrations, 1, "a re-check registers nothing")
    }

    func testAHelperAwaitingApprovalReplacesTheReason() throws {
        // What is left to do is approving it, which the refresh shows.
        let harness = try failRegistration()

        harness.helper.state = .requiresApproval
        harness.coordinator.refreshMicrophoneStatus()
        XCTAssertEqual(harness.coordinator.micStatus, .needsApproval)

        // Once replaced, the reason is not brought back.
        harness.helper.state = .notRegistered
        harness.coordinator.refreshMicrophoneStatus()
        XCTAssertEqual(harness.coordinator.micStatus, .notSetUp)
    }

    func testAnApprovedHelpersCheckReplacesTheReason() async throws {
        let harness = try failRegistration()

        harness.helper.state = .enabled
        harness.coordinator.refreshMicrophoneStatus()
        harness.helper.answerCheck("6")
        let ready = await waitUntil { harness.coordinator.micStatus == .ready }

        XCTAssertTrue(ready)
    }
}

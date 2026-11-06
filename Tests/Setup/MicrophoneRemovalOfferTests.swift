@testable import LemurCam
import XCTest

/// While a restart was asked for (an older audio helper still serving the app), the
/// Settings status card offered no action at all, though the microphone was installed
/// and removing it needs no copy sealed to root. It now offers "Remove Microphone…"
/// there when a driver is installed. Against a fake helper.
@MainActor
internal final class MicrophoneRemovalOfferTests: XCTestCase {
    private var fixture: SetupCoordinatorFixture?

    override func setUp() async throws {
        try await super.setUp()
        fixture = try SetupCoordinatorFixture()
    }

    override func tearDown() async throws {
        fixture?.cleanUp()
        fixture = nil
        try await super.tearDown()
    }

    func testRemovalIsOfferedWhenTheMicrophoneIsInstalled() {
        XCTAssertTrue(MicrophoneRemoval.isOffered(status: .ready, installedVersion: "6"))
        XCTAssertTrue(MicrophoneRemoval.isOffered(status: .needsReboot, installedVersion: "6"))
        XCTAssertFalse(MicrophoneRemoval.isOffered(status: .needsReboot, installedVersion: nil), "nothing to remove")
        let others: [MicrophoneStatus] = [.unknown, .checking, .notSetUp, .needsApproval, .installing, .failed("x")]
        for status in others {
            XCTAssertFalse(MicrophoneRemoval.isOffered(status: status, installedVersion: "6"), "\(status)")
        }
    }

    /// The reported case: an install through an older helper left an unsealed copy.
    /// The microphone can be removed without restarting first.
    func testAMicrophoneWaitingForARestartCanBeRemoved() async throws {
        let harness = try XCTUnwrap(fixture)
        harness.coordinator.updateMicrophone()
        try XCTUnwrap(harness.helper.installs.last)(.succeeded)
        let verifying = await waitUntil { harness.helper.checks.count == 1 }
        XCTAssertTrue(verifying)
        harness.helper.answerCheck("6", sealed: false)
        let rebootAsked = await waitUntil { harness.coordinator.micStatus == .needsReboot }
        XCTAssertTrue(rebootAsked)
        XCTAssertTrue(harness.coordinator.offersMicrophoneRemoval)

        harness.coordinator.disableMicrophone()
        XCTAssertEqual(harness.helper.removals.count, 1)
        try XCTUnwrap(harness.helper.removals.last)(.succeeded)
        let checking = await waitUntil { harness.helper.checks.count == 2 }
        XCTAssertTrue(checking)
        harness.helper.answerCheck(nil)
        let removed = await waitUntil { harness.coordinator.micStatus == .notSetUp }
        XCTAssertTrue(removed)
        XCTAssertFalse(harness.coordinator.offersMicrophoneRemoval)
    }

    /// Enable through a helper already known to be stale asks for the restart with
    /// nothing installed: there is nothing to remove.
    func testNothingToRemoveWhileARestartIsAskedForBeforeAnInstall() throws {
        let harness = try XCTUnwrap(fixture)
        harness.staleHelperMarker.record()

        harness.coordinator.enableMicrophone()

        XCTAssertEqual(harness.coordinator.micStatus, .needsReboot)
        XCTAssertTrue(harness.helper.installs.isEmpty)
        XCTAssertFalse(harness.coordinator.offersMicrophoneRemoval)
    }
}

@testable import LemurCam
import XCTest

/// With a stale (v1.5) audio helper serving the app and no driver installed, Enable
/// asked for a restart (the helper can't install a sealed copy), but the next check
/// (the setup window's poll, the app becoming active) found no driver and showed
/// "Not set up" again, offering Enable, which can't work before the restart. It was
/// reached by removing a microphone waiting for a restart, then enabling it again.
/// The restart ask now stays up while checks find that helper. Against a fake helper.
@MainActor
internal final class MicrophoneRestartAskTests: XCTestCase {
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

    /// Poll as the setup window does, the helper answering `helper` with no driver,
    /// and return whether the restart ask came down. A poll sends a check only once
    /// the previous one was applied, so each one sent shows the one before landed.
    private func pollWithNoDriver(
        _ harness: SetupCoordinatorFixture, helper: AudioHelperIdentity, times: Int = 3
    ) async -> Bool {
        for _ in 0..<times {
            let sent = harness.helper.checks.count
            harness.coordinator.refreshMicrophoneStatus()
            XCTAssertEqual(harness.helper.checks.count, sent + 1, "the previous check was applied")
            harness.helper.answerCheck(nil, helper: helper)
            if await waitUntil(timeout: 0.2, { harness.coordinator.micStatus != .needsReboot }) { return true }
        }
        return false
    }

    /// The first launch after an update, with no driver: nothing was asked for yet,
    /// so Enable is offered. Pressing it asks for the restart, and that stays.
    func testEnableThroughAStaleHelperKeepsAskingForTheRestart() async throws {
        let harness = try XCTUnwrap(fixture)
        harness.coordinator.refreshMicrophoneStatus()
        harness.helper.answerCheck(nil, helper: .stale)
        let notSetUp = await waitUntil { harness.coordinator.micStatus == .notSetUp }
        XCTAssertTrue(notSetUp, "no restart asked for before the user asks to install")

        harness.coordinator.enableMicrophone()
        XCTAssertEqual(harness.coordinator.micStatus, .needsReboot)

        let askDropped = await pollWithNoDriver(harness, helper: .stale)
        XCTAssertFalse(askDropped)
        XCTAssertTrue(harness.helper.installs.isEmpty)
        XCTAssertFalse(harness.coordinator.offersMicrophoneRemoval, "nothing to remove")
    }

    /// The reported path: remove a microphone waiting for a restart, then Enable.
    func testEnableAfterRemovingKeepsAskingForTheRestart() async throws {
        let harness = try XCTUnwrap(fixture)
        harness.coordinator.refreshMicrophoneStatus()
        harness.helper.answerCheck("6", sealed: false, helper: .stale)
        let rebootAsked = await waitUntil { harness.coordinator.micStatus == .needsReboot }
        XCTAssertTrue(rebootAsked)

        harness.coordinator.disableMicrophone()
        try XCTUnwrap(harness.helper.removals.last)(.succeeded)
        let checking = await waitUntil { harness.helper.checks.count == 2 }
        XCTAssertTrue(checking)
        harness.helper.answerCheck(nil, helper: .stale)
        let removed = await waitUntil { harness.coordinator.micStatus == .notSetUp }
        XCTAssertTrue(removed, "the user removed it: nothing is asked for")

        harness.coordinator.enableMicrophone()
        XCTAssertEqual(harness.coordinator.micStatus, .needsReboot)
        let askDropped = await pollWithNoDriver(harness, helper: .stale)
        XCTAssertFalse(askDropped)
        XCTAssertTrue(harness.helper.installs.isEmpty)
    }

    /// A check that doesn't tell which helper answered keeps the ask while the stale
    /// mark is set.
    func testACheckThatDoesNotTellKeepsTheAskWhileMarked() async throws {
        let harness = try XCTUnwrap(fixture)
        harness.staleHelperMarker.record()
        harness.coordinator.enableMicrophone()
        XCTAssertEqual(harness.coordinator.micStatus, .needsReboot)

        let askDropped = await pollWithNoDriver(harness, helper: .notIdentified)

        XCTAssertFalse(askDropped)
    }

    /// The stale helper stopped and a current one answers: Enable is offered again,
    /// and goes through it.
    func testACurrentHelperEndsTheAsk() async throws {
        let harness = try XCTUnwrap(fixture)
        harness.staleHelperMarker.record()
        harness.coordinator.enableMicrophone()
        XCTAssertEqual(harness.coordinator.micStatus, .needsReboot)

        let askDropped = await pollWithNoDriver(harness, helper: .current, times: 1)

        XCTAssertTrue(askDropped)
        XCTAssertEqual(harness.coordinator.micStatus, .notSetUp)
        harness.coordinator.enableMicrophone()
        XCTAssertEqual(harness.helper.installs.count, 1)
    }

    // MARK: - Decisions

    private func decide(
        _ helper: AudioHelperIdentity, _ status: MicrophoneStatus, seen: Bool = false
    ) -> MicrophoneVersionReply {
        MicrophoneVersionReply.decide(
            InstalledDriverCheck(reachable: true, version: nil, sealed: false, helper: helper),
            context: MicrophoneCheckContext(currentStatus: status, staleHelperSeen: seen, bundledVersion: "6")
        )
    }

    func testNoDriverBehindAStaleHelperKeepsARestartAsk() {
        XCTAssertEqual(decide(.stale, .needsReboot, seen: true), .setStatus(.needsReboot))
        XCTAssertEqual(decide(.notIdentified, .needsReboot, seen: true), .setStatus(.needsReboot))
    }

    func testNoDriverIsNotSetUpWithoutARestartAsk() {
        let others: [MicrophoneStatus] = [.unknown, .checking, .notSetUp, .installing, .ready, .failed("x")]
        for status in others {
            XCTAssertEqual(decide(.stale, status, seen: true), .setStatus(.notSetUp), "\(status)")
        }
    }

    func testNoDriverIsNotSetUpOnceNoStaleHelperServes() {
        XCTAssertEqual(decide(.current, .needsReboot), .setStatus(.notSetUp))
        XCTAssertEqual(decide(.current, .needsReboot, seen: true), .setStatus(.notSetUp), "it says it is current")
        XCTAssertEqual(decide(.notIdentified, .needsReboot), .setStatus(.notSetUp))
    }

    func testTheRemovalConfirmationSaysWhenItCanBeReEnabled() {
        let anytime = MicrophoneStatusCopy.removal(restartAsked: false)
        let afterRestart = MicrophoneStatusCopy.removal(restartAsked: true)

        XCTAssertTrue(anytime.contains("re-enable it anytime"))
        XCTAssertFalse(afterRestart.contains("anytime"))
        XCTAssertTrue(afterRestart.contains("once you restart your Mac"))
    }
}

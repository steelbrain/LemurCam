@testable import LemurCam
import XCTest

/// The stale-helper mark lasted until the Mac restarted, but a stale (v1.5) helper
/// can stop before that: turned off in Login Items, crashed, or killed. launchd then
/// starts the current one, which seals what it installs, yet every check that boot
/// still asked for a restart and refused to install. Each check now tells which
/// helper answered, by whether it answers `helperBuild`: a current one clears the
/// mark, a stale one sets it. Against a fake helper.
@MainActor
internal final class StaleHelperIdentityTests: XCTestCase {
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

    /// The reported case: marked stale this boot, then a check answered by a current
    /// helper. The unsealed copy is offered for Update, which installs again.
    func testACurrentHelperClearsTheMark() async throws {
        let harness = try XCTUnwrap(fixture)
        harness.staleHelperMarker.record()

        harness.coordinator.refreshMicrophoneStatus()
        harness.helper.answerCheck("6", sealed: false, helper: .current)
        let ready = await waitUntil { harness.coordinator.micStatus == .ready }

        XCTAssertTrue(ready, "no restart asked for")
        XCTAssertFalse(harness.staleHelperMarker.isSet)
        XCTAssertEqual(harness.coordinator.microphoneUpdateReason, .unsealed)
        harness.coordinator.updateMicrophone()
        XCTAssertEqual(harness.helper.installs.count, 1, "the install is no longer refused")
    }

    /// Without the identity (an unreachable check, say), the mark holds as before.
    func testACheckThatDoesNotTellKeepsTheMark() async throws {
        let harness = try XCTUnwrap(fixture)
        harness.staleHelperMarker.record()

        harness.coordinator.refreshMicrophoneStatus()
        harness.helper.answerCheck("6", sealed: false)
        let rebootAsked = await waitUntil { harness.coordinator.micStatus == .needsReboot }

        XCTAssertTrue(rebootAsked)
        XCTAssertTrue(harness.staleHelperMarker.isSet)
        harness.coordinator.updateMicrophone()
        XCTAssertTrue(harness.helper.installs.isEmpty)
    }

    /// A stale helper found by a check is marked before any install through it: the
    /// Update it would have offered for an unsealed copy only cut audio again for an
    /// unsealed copy.
    func testAStaleHelperIsMarkedWithoutAnInstall() async throws {
        let harness = try XCTUnwrap(fixture)

        harness.coordinator.refreshMicrophoneStatus()
        harness.helper.answerCheck("6", sealed: false, helper: .stale)
        let rebootAsked = await waitUntil { harness.coordinator.micStatus == .needsReboot }

        XCTAssertTrue(rebootAsked)
        XCTAssertTrue(harness.staleHelperMarker.isSet)
        XCTAssertTrue(harness.coordinator.offersMicrophoneRemoval)
        harness.coordinator.updateMicrophone()
        XCTAssertTrue(harness.helper.installs.isEmpty)
    }

    /// A sealed copy works whichever helper serves it; installing through a stale one
    /// is still refused.
    func testASealedCopyIsReadyBehindAStaleHelper() async throws {
        let harness = try XCTUnwrap(fixture)
        harness.helper.bundledDriverVersion = "7"

        harness.coordinator.refreshMicrophoneStatus()
        harness.helper.answerCheck("6", helper: .stale)
        let ready = await waitUntil { harness.coordinator.micStatus == .ready }

        XCTAssertTrue(ready)
        harness.coordinator.updateMicrophone()
        XCTAssertEqual(harness.coordinator.micStatus, .needsReboot)
        XCTAssertTrue(harness.helper.installs.isEmpty)
    }

    // MARK: - Decisions

    func testWhatTheHelperAnswersTellsWhichOneItIs() {
        XCTAssertEqual(AudioHelperIdentity(helperBuild: LemurAudioHelper.helperBuild), .current)
        XCTAssertEqual(AudioHelperIdentity(helperBuild: ""), .current, "any answer")
        XCTAssertEqual(AudioHelperIdentity(helperBuild: nil), .stale)
        XCTAssertEqual(InstalledDriverCheck.unreachable.helper, .notIdentified)
    }

    func testAnUnsealedCopyRightAfterAnInstallByACurrentHelperIsNotARestart() {
        func decide(_ helper: AudioHelperIdentity, verifying: Bool, stale: Bool) -> MicrophoneVersionReply {
            MicrophoneVersionReply.decide(
                InstalledDriverCheck(reachable: true, version: "6", sealed: false, helper: helper),
                context: MicrophoneCheckContext(
                    currentStatus: .installing, verifyingInstall: verifying, staleHelperSeen: stale, bundledVersion: "6"
                )
            )
        }
        XCTAssertEqual(decide(.current, verifying: true, stale: false), .setStatus(.ready))
        XCTAssertEqual(decide(.current, verifying: false, stale: true), .setStatus(.ready))
        XCTAssertEqual(decide(.stale, verifying: false, stale: false), .setStatus(.needsReboot))
        XCTAssertEqual(decide(.notIdentified, verifying: true, stale: false), .setStatus(.needsReboot))
        XCTAssertEqual(decide(.notIdentified, verifying: false, stale: false), .setStatus(.ready))
    }

    func testTheMarkFollowsTheIdentity() throws {
        let suite = "StaleHelperIdentityTests.marker"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let marker = StaleHelperMarker(defaults: defaults, bootTime: { 42 })
        var seen = false

        marker.update(from: .stale, seen: &seen)
        XCTAssertTrue(seen)
        XCTAssertTrue(marker.isSet)

        marker.update(from: .notIdentified, seen: &seen)
        XCTAssertTrue(seen, "a check that did not tell changes nothing")
        XCTAssertTrue(marker.isSet)

        marker.update(from: .current, seen: &seen)
        XCTAssertFalse(seen)
        XCTAssertFalse(marker.isSet)
        XCTAssertFalse(StaleHelperMarker(defaults: defaults, bootTime: { 42 }).isSet, "cleared for the next launch too")
    }
}

@testable import LemurCam
import XCTest

/// Pins how the installed-driver check drives `micStatus`. An unreachable helper must
/// not leave a spinner up forever with no action, but must not knock a known status
/// over either. A driver copy not sealed to root must be offered for reinstall, and
/// one that is still unsealed right after an install means a stale helper: ask for a
/// restart instead of claiming success or reinstalling in a loop.
internal final class MicrophoneVersionReplyTests: XCTestCase {
    private let sealed = InstalledDriverCheck(reachable: true, version: "6", sealed: true)
    private let unsealed = InstalledDriverCheck(reachable: true, version: "6", sealed: false)
    private let none = InstalledDriverCheck(reachable: true, version: nil, sealed: false)

    private func decide(
        _ check: InstalledDriverCheck,
        _ status: MicrophoneStatus,
        configure: (inout MicrophoneCheckContext) -> Void = { _ in }
    ) -> MicrophoneVersionReply {
        var context = MicrophoneCheckContext(currentStatus: status, bundledVersion: "6")
        configure(&context)
        return MicrophoneVersionReply.decide(check, context: context)
    }

    // MARK: - Unreachable helper

    func testUnreachableHelperBeforeAnyStatusFails() {
        XCTAssertEqual(decide(.unreachable, .unknown), .setStatus(.failed(MicrophoneVersionReply.unreachableMessage)))
    }

    func testUnreachableHelperKeepsAKnownStatus() {
        let known: [MicrophoneStatus] = [.ready, .notSetUp, .needsApproval, .needsReboot, .failed("earlier")]
        for status in known {
            XCTAssertEqual(
                decide(.unreachable, status) { $0.autoInstallPending = true },
                .keepStatus,
                "Unreachable helper should not replace \(status)"
            )
        }
    }

    // MARK: - Installed driver

    func testSealedDriverIsReady() {
        XCTAssertEqual(decide(sealed, .unknown) { $0.autoInstallPending = true }, .setStatus(.ready))
    }

    func testReachableReplyRecoversFromTheUnreachableFailure() {
        XCTAssertEqual(decide(sealed, .failed(MicrophoneVersionReply.unreachableMessage)), .setStatus(.ready))
    }

    func testNoDriverIsNotSetUp() {
        XCTAssertEqual(decide(none, .unknown), .setStatus(.notSetUp))
    }

    func testNoDriverDuringGuidedSetupInstallsIt() {
        XCTAssertEqual(decide(none, .needsApproval) { $0.autoInstallPending = true }, .installDriver)
    }

    func testUnsealedDriverIsReadyWithAReinstallOffered() {
        // Working, but anyone running as the user could replace it: the status card
        // offers Update (see the update reason), without reinstalling on its own.
        XCTAssertEqual(decide(unsealed, .unknown), .setStatus(.ready))
        XCTAssertEqual(MicrophoneUpdateReason.reason(installed: "6", bundled: "6", sealed: false), .unsealed)
    }

    func testUnsealedRightAfterAnInstallAsksForARestart() {
        // The helper reported success but installed a user-owned copy: a helper from
        // before the update is still running. Claiming success would leave it so.
        XCTAssertEqual(decide(unsealed, .installing) { $0.verifyingInstall = true }, .setStatus(.needsReboot))
    }

    func testStaleHelperKeepsAskingForTheRestart() {
        XCTAssertEqual(decide(unsealed, .needsReboot) { $0.staleHelperSeen = true }, .setStatus(.needsReboot))
        XCTAssertEqual(decide(sealed, .needsReboot) { $0.staleHelperSeen = true }, .setStatus(.ready),
                       "a sealed copy (e.g. after a restart) is ready again")
    }

    func testSealedRightAfterAnInstallIsReady() {
        XCTAssertEqual(decide(sealed, .installing) { $0.verifyingInstall = true }, .setStatus(.ready))
    }

    // MARK: - Update reason

    func testUpdateReasons() {
        XCTAssertEqual(MicrophoneUpdateReason.reason(installed: "5", bundled: "6", sealed: true), .newerVersion)
        XCTAssertEqual(MicrophoneUpdateReason.reason(installed: "5", bundled: "6", sealed: false), .unsealed)
        XCTAssertNil(MicrophoneUpdateReason.reason(installed: "6", bundled: "6", sealed: true))
        XCTAssertNil(MicrophoneUpdateReason.reason(installed: "7", bundled: "6", sealed: true))
        XCTAssertNil(MicrophoneUpdateReason.reason(installed: nil, bundled: "6", sealed: false), "nothing installed")
    }

    func testAForgedVersionDoesNotHideAnUnsealedCopy() {
        // A user-owned copy can claim any version; it still needs the reinstall.
        XCTAssertEqual(MicrophoneUpdateReason.reason(installed: "999", bundled: "6", sealed: false), .unsealed)
    }
}

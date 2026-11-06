@testable import LemurCam
import XCTest

/// Pins how the helper's installed-driver-version reply drives `micStatus`. An
/// unreachable helper must not leave the first query's `.unknown` spinner up
/// forever with no action, but must not knock a known status over either.
internal final class MicrophoneVersionReplyTests: XCTestCase {

    func testUnreachableHelperBeforeAnyStatusFails() {
        XCTAssertEqual(
            MicrophoneVersionReply.decide(
                reachable: false, version: nil, currentStatus: .unknown, autoInstallPending: false
            ),
            .setStatus(.failed(MicrophoneVersionReply.unreachableMessage))
        )
    }

    func testUnreachableHelperKeepsAKnownStatus() {
        let known: [MicrophoneStatus] = [.ready, .notSetUp, .needsApproval, .failed("earlier")]
        for status in known {
            XCTAssertEqual(
                MicrophoneVersionReply.decide(
                    reachable: false, version: nil, currentStatus: status, autoInstallPending: true
                ),
                .keepStatus,
                "Unreachable helper should not replace \(status)"
            )
        }
    }

    func testInstalledDriverIsReady() {
        XCTAssertEqual(
            MicrophoneVersionReply.decide(
                reachable: true, version: "3", currentStatus: .unknown, autoInstallPending: true
            ),
            .setStatus(.ready)
        )
    }

    func testReachableReplyRecoversFromTheUnreachableFailure() {
        XCTAssertEqual(
            MicrophoneVersionReply.decide(
                reachable: true,
                version: "3",
                currentStatus: .failed(MicrophoneVersionReply.unreachableMessage),
                autoInstallPending: false
            ),
            .setStatus(.ready)
        )
    }

    func testNoDriverIsNotSetUp() {
        XCTAssertEqual(
            MicrophoneVersionReply.decide(
                reachable: true, version: nil, currentStatus: .unknown, autoInstallPending: false
            ),
            .setStatus(.notSetUp)
        )
    }

    func testNoDriverDuringGuidedSetupInstallsIt() {
        XCTAssertEqual(
            MicrophoneVersionReply.decide(
                reachable: true, version: nil, currentStatus: .needsApproval, autoInstallPending: true
            ),
            .installDriver
        )
    }
}

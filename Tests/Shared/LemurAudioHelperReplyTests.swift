@testable import LemurCam
import XCTest

/// Covers the coreaudiod-restart result policy: the install/uninstall outcome is
/// decided by a status check (does coreaudiod come back?), not by the unreliable
/// exit code of `launchctl kickstart -k`. Regression test for spurious
/// "install/remove failed" reports.
internal final class LemurAudioHelperReplyTests: XCTestCase {
    func testStatusCheckSuccessReportsNoError() {
        XCTAssertNil(LemurAudioHelper.coreAudioRestartResult(statusCheckExitCode: 0))
    }

    func testStatusCheckFailureReportsError() {
        let result = LemurAudioHelper.coreAudioRestartResult(statusCheckExitCode: 113)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.contains("113"), true)
    }

    func testProcessSpawnFailureReportsError() {
        // -1 is the helper's sentinel for "launchctl could not be launched".
        XCTAssertNotNil(LemurAudioHelper.coreAudioRestartResult(statusCheckExitCode: -1))
    }
}

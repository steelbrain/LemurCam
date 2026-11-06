@testable import LemurCam
import XCTest

/// Covers the coreaudiod-restart result policy. A restart is proven only by a new
/// coreaudiod PID: `launchctl print` exits 0 for any registered job (running or
/// not), so the old status check could never fail, and `launchctl kickstart -k`'s
/// own exit code is not trusted alone (it has been seen non-zero after a restart
/// that worked, the cause of spurious "install/remove failed" reports).
internal final class LemurAudioHelperReplyTests: XCTestCase {
    func testNewPidIsSuccessEvenIfKickstartReportedFailure() {
        XCTAssertNil(LemurAudioHelper.coreAudioRestartResult(kickstartStatus: 0, pidBefore: 100, pidAfter: 200))
        XCTAssertNil(LemurAudioHelper.coreAudioRestartResult(kickstartStatus: 37, pidBefore: 100, pidAfter: 200))
    }

    func testStartingAStoppedCoreAudioIsSuccess() {
        XCTAssertNil(LemurAudioHelper.coreAudioRestartResult(kickstartStatus: 0, pidBefore: nil, pidAfter: 300))
    }

    func testSamePidMeansNoRestartAndReportsKickstartStatus() {
        let result = LemurAudioHelper.coreAudioRestartResult(kickstartStatus: 113, pidBefore: 100, pidAfter: 100)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.contains("113"), true)
        XCTAssertNotNil(LemurAudioHelper.coreAudioRestartResult(kickstartStatus: 0, pidBefore: 100, pidAfter: 100))
    }

    func testNotRunningAfterwardsIsFailure() {
        XCTAssertNotNil(LemurAudioHelper.coreAudioRestartResult(kickstartStatus: 0, pidBefore: 100, pidAfter: nil))
        XCTAssertNotNil(LemurAudioHelper.coreAudioRestartResult(kickstartStatus: 0, pidBefore: nil, pidAfter: nil))
    }

    func testProcessSpawnFailureReportsError() {
        // -1 is the helper's sentinel for "launchctl could not be launched".
        XCTAssertNotNil(LemurAudioHelper.coreAudioRestartResult(kickstartStatus: -1, pidBefore: 100, pidAfter: 100))
    }
}

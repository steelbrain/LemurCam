import Darwin
@testable import LemurCam
import XCTest

/// Drives the helper's coreaudiod restart loop with an injected launchctl runner and
/// PID source (audit finding C9): success needs a new coreaudiod process, the loop
/// waits a bounded time for it, and kickstart's status is reported, not trusted.
internal final class CoreAudioRestarterTests: XCTestCase {
    private final class Fake {
        var pids: [pid_t?]
        var kickstartStatus: Int32
        var launchctlCalls: [[String]] = []
        var pauses = 0
        private var pidReads = 0

        init(pids: [pid_t?], kickstartStatus: Int32 = 0) {
            self.pids = pids
            self.kickstartStatus = kickstartStatus
        }

        func restarter(maxChecks: Int = 5) -> CoreAudioRestarter {
            CoreAudioRestarter(
                runLaunchctl: { [self] arguments in
                    launchctlCalls.append(arguments)
                    return kickstartStatus
                },
                coreAudioPID: { [self] in
                    defer { pidReads += 1 }
                    return pids[min(pidReads, pids.count - 1)]
                },
                pause: { [self] in pauses += 1 },
                maxChecks: maxChecks
            )
        }
    }

    func testKickstartsCoreAudioOnce() {
        let fake = Fake(pids: [100, 200])
        XCTAssertNil(fake.restarter().restart())
        XCTAssertEqual(fake.launchctlCalls, [["kickstart", "-k", "system/com.apple.audio.coreaudiod"]])
    }

    func testWaitsForTheNewInstance() {
        // Before: 100. After kickstart the old one is still exiting, then it is gone,
        // then launchd's replacement appears.
        let fake = Fake(pids: [100, 100, nil, 300])
        XCTAssertNil(fake.restarter().restart())
        XCTAssertEqual(fake.pauses, 2)
    }

    func testGivesUpWhenThePidNeverChanges() {
        let fake = Fake(pids: [100], kickstartStatus: 3)
        let result = fake.restarter(maxChecks: 4).restart()
        XCTAssertEqual(result?.contains("did not restart"), true, result ?? "nil")
        XCTAssertEqual(result?.contains("status 3"), true, result ?? "nil")
        XCTAssertEqual(fake.pauses, 3, "bounded wait")
    }

    func testReportsCoreAudioNotComingBack() {
        let fake = Fake(pids: [100, nil])
        XCTAssertEqual(fake.restarter().restart()?.contains("not running"), true)
    }

    func testNonZeroKickstartWithANewInstanceIsSuccess() {
        let fake = Fake(pids: [100, 200], kickstartStatus: 1)
        XCTAssertNil(fake.restarter().restart())
    }

    func testLaunchctlSpawnFailureDoesNotWait() {
        let fake = Fake(pids: [100], kickstartStatus: -1)
        XCTAssertNotNil(fake.restarter().restart())
        XCTAssertEqual(fake.pauses, 0)
    }

    func testFindsTheRunningSystemCoreAudio() throws {
        guard let pid = CoreAudioProcess.currentPID() else {
            throw XCTSkip("coreaudiod is not running on this machine")
        }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        XCTAssertEqual(sysctl(&mib, 4, &info, &size, nil, 0), 0)
        XCTAssertEqual(info.kp_eproc.e_ppid, 1, "launched by launchd")
        XCTAssertNotEqual(info.kp_eproc.e_ucred.cr_uid, getuid(), "not a same-named process of ours")
    }
}

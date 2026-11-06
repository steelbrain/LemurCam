import Foundation
@testable import LemurCam
import XCTest

/// The helper runs `launchctl` on its one operations queue; a run that never ends
/// must not hold that queue (and every later request) forever.
internal final class BoundedProcessTests: XCTestCase {
    func testReturnsTheExitStatus() {
        XCTAssertEqual(BoundedProcess.run("/usr/bin/true", [], timeout: 10), 0)
        XCTAssertEqual(BoundedProcess.run("/usr/bin/false", [], timeout: 10), 1)
    }

    func testToolThatCannotBeLaunchedIsMinusOne() {
        XCTAssertEqual(BoundedProcess.run("/nonexistent/launchctl", [], timeout: 10), -1)
    }

    func testToolPastItsDeadlineIsTerminated() {
        let start = Date()
        let status = BoundedProcess.run("/bin/sleep", ["30"], timeout: 0.2, killGrace: 2)
        XCTAssertEqual(status, SIGTERM, "ended by the SIGTERM sent at the deadline")
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testToolIgnoringSIGTERMIsKilled() {
        let start = Date()
        // `exec` keeps the ignored SIGTERM and leaves no orphaned child behind.
        let script = "trap '' TERM; exec /bin/sleep 30"
        let status = BoundedProcess.run("/bin/sh", ["-c", script], timeout: 0.2, killGrace: 0.5)
        XCTAssertEqual(status, SIGKILL)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }
}

import Foundation
@testable import LemurCam
import XCTest

/// Pins when the privileged helper ends itself. It must exit once nothing has used
/// it for the grace period (so launchd runs the current binary for the next request,
/// instead of a helper from before an app update serving until reboot), and never
/// while a connection is open or an operation is running.
internal final class HelperIdleExitTests: XCTestCase {
    /// Collects scheduled timers so the test decides when each one fires.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var timers: [(delay: TimeInterval, action: @Sendable () -> Void)] = []
        private(set) var exits = 0

        var scheduledDelays: [TimeInterval] { lock.withLock { timers.map(\.delay) } }

        func schedule(_ delay: TimeInterval, _ action: @escaping @Sendable () -> Void) {
            lock.withLock { timers.append((delay, action)) }
        }

        /// Fire every pending timer, oldest first.
        func fireAll() {
            let due = lock.withLock { () -> [@Sendable () -> Void] in
                defer { timers.removeAll() }
                return timers.map(\.action)
            }
            due.forEach { $0() }
        }

        func recordExit() {
            lock.withLock { exits += 1 }
        }

        func idleExit(grace: TimeInterval = 15) -> HelperIdleExit {
            HelperIdleExit(
                grace: grace,
                schedule: { [self] delay, action in schedule(delay, action) },
                exit: { [self] in recordExit() }
            )
        }
    }

    func testLaunchWithNoRequestExitsAfterTheGracePeriod() {
        let clock = Clock()
        let idle = clock.idleExit()
        idle.start()
        XCTAssertEqual(clock.scheduledDelays, [15])

        clock.fireAll()
        XCTAssertEqual(clock.exits, 1)
        XCTAssertNil(idle.begin(), "no new work once the helper is exiting")
    }

    func testOpenConnectionKeepsTheHelperUp() {
        let clock = Clock()
        let idle = clock.idleExit()
        idle.start()
        let connection = idle.begin()
        clock.fireAll()
        XCTAssertEqual(clock.exits, 0)

        connection?.end()
        clock.fireAll()
        XCTAssertEqual(clock.exits, 1)
    }

    func testOperationOutlivingItsConnectionKeepsTheHelperUp() {
        let clock = Clock()
        let idle = clock.idleExit()
        let connection = idle.begin()
        let operation = idle.begin()
        connection?.end() // the client went away mid-install
        clock.fireAll()
        XCTAssertEqual(clock.exits, 0)

        operation?.end()
        clock.fireAll()
        XCTAssertEqual(clock.exits, 1)
    }

    func testOnlyTheLatestIdleTimerCounts() {
        let clock = Clock()
        let idle = clock.idleExit()
        idle.start()
        // A request opens and closes within the first grace period: the timer armed
        // at launch must not end the helper early, only the one armed after it.
        idle.begin()?.end()
        XCTAssertEqual(clock.scheduledDelays.count, 2)
        clock.fireAll()
        XCTAssertEqual(clock.exits, 1)
    }

    func testEndingAnActivityTwiceCountsOnce() {
        let clock = Clock()
        let idle = clock.idleExit()
        let first = idle.begin()
        let second = idle.begin()
        first?.end()
        first?.end()
        clock.fireAll()
        XCTAssertEqual(clock.exits, 0, "the second connection is still open")

        second?.end()
        clock.fireAll()
        XCTAssertEqual(clock.exits, 1)
    }

    func testGraceOutlastsLaunchdSpawnThrottle() {
        // launchd spawns a job at most once every 10 s by default; a helper that
        // lives longer than that is relaunched for the next request without delay.
        XCTAssertGreaterThan(HelperIdleExit.defaultGrace, 10)
    }
}

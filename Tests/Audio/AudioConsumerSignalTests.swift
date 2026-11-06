// This import brings in the app's bridging header (the driver's C signal helpers), a use the analyzer misses.
// swiftlint:disable:next unused_import
@testable import LemurCam
import XCTest

/// The driver posted consumerStarted and consumerStopped after releasing the lock
/// that orders its IO count, so one client's last StopIO and another's first
/// StartIO could post in the opposite order: the app, which takes each
/// notification's direction as the state, ended with no consumer while the second
/// client recorded. The driver now posts what `lemur_audio_io_started` and
/// `lemur_audio_io_stopped` return before unlocking, so the notifications leave in
/// the order the count changed. These pin that, posted in that order, the latest
/// notification always matches whether a client is running.
internal final class AudioConsumerSignalTests: XCTestCase {
    private enum Posted: Equatable {
        case started
        case stopped
    }

    /// One client's StartIO (`start`) or StopIO applied to `count`, as the driver
    /// does under its lock, and what it posts.
    private func apply(start: Bool, to count: inout UInt32) -> Posted? {
        let name = start ? lemur_audio_io_started(&count) : lemur_audio_io_stopped(&count)
        guard let name else { return nil }
        let posted = String(cString: name)
        if posted == LEMUR_AUDIO_NOTIFY_CONSUMER_STARTED { return .started }
        XCTAssertEqual(posted, LEMUR_AUDIO_NOTIFY_CONSUMER_STOPPED)
        return .stopped
    }

    func testOnlyTheFirstStartAndTheLastStopPost() {
        var count: UInt32 = 0

        XCTAssertEqual(apply(start: true, to: &count), .started)
        XCTAssertNil(apply(start: true, to: &count))
        XCTAssertEqual(count, 2)
        XCTAssertNil(apply(start: false, to: &count))
        XCTAssertEqual(apply(start: false, to: &count), .stopped)
        XCTAssertEqual(count, 0)
    }

    /// The HAL should not send it, but a StopIO with no client counted neither wraps
    /// the count nor says a client runs.
    func testAStopWithNoClientCountedSaysStopped() {
        var count: UInt32 = 0

        XCTAssertEqual(apply(start: false, to: &count), .stopped)
        XCTAssertEqual(count, 0)
    }

    /// The reported case (one client's last stop and another's first start, in either
    /// order) and every other order in which three clients each start and stop: after
    /// each change, the last notification posted (consumerStopped from the driver's
    /// Initialize before any) says whether a client runs IO.
    func testTheLastNotificationAlwaysMatchesTheCount() {
        var orders = 0
        forEachInterleaving(clients: 3, operations: 2) { order in
            orders += 1
            var count: UInt32 = 0
            var latest = Posted.stopped
            var started = Set<Int>()
            for client in order {
                // Each client's first operation is its start, its second its stop.
                let start = started.insert(client).inserted
                if let posted = apply(start: start, to: &count) {
                    XCTAssertNotEqual(posted, latest, "each notification changes the state: \(order)")
                    latest = posted
                }
                XCTAssertEqual(latest, count > 0 ? .started : .stopped, "\(order)")
            }
            XCTAssertEqual(count, 0)
        }
        XCTAssertEqual(orders, 90, "6! / (2! 2! 2!) orders")
    }

    /// Calls `body` with each order in which `clients` clients can each run their
    /// `operations` operations, as the client to run next at each step.
    private func forEachInterleaving(clients: Int, operations: Int, _ body: ([Int]) -> Void) {
        var remaining = [Int](repeating: operations, count: clients)
        var order: [Int] = []
        func extend() {
            guard order.count < clients * operations else {
                body(order)
                return
            }
            for client in 0..<clients where remaining[client] > 0 {
                remaining[client] -= 1
                order.append(client)
                extend()
                order.removeLast()
                remaining[client] += 1
            }
        }
        extend()
    }
}

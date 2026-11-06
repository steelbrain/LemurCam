import Foundation
import IPCamKit
@testable import LemurCam
import os
import XCTest

private final class Flag: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)

    var isSet: Bool {
        state.withLock { $0 }
    }

    func set() {
        state.withLock { $0 = true }
    }
}

private struct RefusedStart: Error {}

/// Locks the connect timeout. IPCamKit's `start()` used to ignore task cancellation,
/// so the timeout called the session's `stop()` to end it. Since IPCamKit 0.5.0 a
/// cancelled `start()` closes the connection at once and throws `CancellationError`,
/// so the timeout cancels it, as a cancelled caller does.
internal final class ConnectTimeoutTests: XCTestCase {
    private let shortTimeout: UInt64 = 50_000_000

    /// A start that waits far longer than any timeout here, and ends at once when
    /// cancelled, as IPCamKit's `start()` does.
    private static func slowStart(cancelled: Flag) -> @Sendable () async throws -> Int {
        {
            do {
                try await Task.sleep(nanoseconds: 10_000_000_000)
            } catch {
                cancelled.set()
                throw error
            }
            return 1
        }
    }

    func testTimeoutCancelsStart() async {
        let cancelled = Flag()
        let started = Date()
        do {
            _ = try await RTSPStreamPipeline.withConnectTimeout(
                nanoseconds: shortTimeout, start: Self.slowStart(cancelled: cancelled)
            )
            XCTFail("a start that never finishes must time out")
        } catch {
            XCTAssertTrue(error is RTSPStreamPipeline.TimeoutError, "expected TimeoutError, got \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0, "the timeout must not wait for start()")
        XCTAssertTrue(cancelled.isSet, "the timeout must cancel start()")
    }

    func testStartThatFinishesInTimeIsReturnedAtOnce() async throws {
        let started = Date()
        let value = try await RTSPStreamPipeline.withConnectTimeout(nanoseconds: 5_000_000_000) { 42 }
        XCTAssertEqual(value, 42)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0, "a start that finished must not wait out the limit")
    }

    func testStartErrorBeforeTheTimeoutIsPassedThrough() async {
        do {
            _ = try await RTSPStreamPipeline.withConnectTimeout(nanoseconds: 5_000_000_000) { () async throws -> Int in
                throw RefusedStart()
            }
            XCTFail("the start error must be thrown")
        } catch {
            XCTAssertTrue(error is RefusedStart, "expected the start error, got \(error)")
        }
    }

    /// Cancelling the caller (a source switch) cancels start, instead of leaving it
    /// connecting to the old camera.
    func testCancellingTheCallerCancelsStart() async {
        let cancelled = Flag()
        let connect = Task {
            try await RTSPStreamPipeline.withConnectTimeout(
                nanoseconds: 10_000_000_000, start: Self.slowStart(cancelled: cancelled)
            )
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        let started = Date()
        connect.cancel()
        let result = await connect.result

        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0, "cancellation must not wait for start()")
        XCTAssertTrue(cancelled.isSet)
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
    }

    // MARK: - IPCamKit's start()

    /// The limit holds for IPCamKit's own `start()`: a camera that takes the
    /// connection and never answers is given up on at the timeout, well before
    /// IPCamKit's 15-second request deadline.
    func testTimeoutEndsTheSessionsStartAgainstACameraThatNeverAnswers() async throws {
        let listener = try SilentLoopbackListener()
        defer { listener.close() }
        let session = RTSPClientSession(url: "rtsp://127.0.0.1:\(listener.port)/stream")

        let started = Date()
        do {
            _ = try await RTSPStreamPipeline.withConnectTimeout(nanoseconds: 200_000_000) {
                try await session.start()
            }
            XCTFail("a camera that never answers must time out")
        } catch {
            XCTAssertTrue(error is RTSPStreamPipeline.TimeoutError, "expected TimeoutError, got \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3.0, "the timeout must end start() at once")
    }

    /// A cancelled connect ends IPCamKit's `start()` at once, with
    /// `CancellationError`.
    func testCancellingTheCallerEndsTheSessionsStart() async throws {
        let listener = try SilentLoopbackListener()
        defer { listener.close() }
        let session = RTSPClientSession(url: "rtsp://127.0.0.1:\(listener.port)/stream")

        let connect = Task {
            try await RTSPStreamPipeline.withConnectTimeout(nanoseconds: 10_000_000_000) {
                try await session.start()
            }
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        let started = Date()
        connect.cancel()
        let result = await connect.result

        XCTAssertLessThan(Date().timeIntervalSince(started), 2.0, "cancellation must end start() at once")
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
    }

    /// A connection cancelled while it connects (a source switch, demand gone) makes
    /// IPCamKit's `start()` throw `CancellationError`. That isn't a failure: the
    /// pipeline reports none, so nothing retries it or shows it.
    func testAConnectionCancelledWhileConnectingReportsNoFailure() async throws {
        let listener = try SilentLoopbackListener()
        defer { listener.close() }
        let pipeline = RTSPStreamPipeline()
        let states = OSAllocatedUnfairLock<[RTSPStreamPipeline.State]>(initialState: [])
        pipeline.onStateChanged = { state, _ in states.withLock { $0.append(state) } }

        _ = pipeline.connect(url: "rtsp://127.0.0.1:\(listener.port)/stream", credentials: nil)
        try await Task.sleep(nanoseconds: 200_000_000)
        pipeline.disconnect()
        // Time for start() to end and the stream task to report anything it would.
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(states.withLock { $0 }, [.connecting, .disconnected])
    }
}

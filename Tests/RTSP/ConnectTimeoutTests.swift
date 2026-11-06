import Foundation
@testable import LemurCam
import os
import XCTest

/// A one-shot latch a fake `start()` waits on. The wait ignores task cancellation,
/// like IPCamKit's `RTSPClientSession.start()`, so only `open()` ends it.
private final class Gate: Sendable {
    private struct State {
        var isOpen = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { state -> Bool in
                if state.isOpen { return true }
                state.waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func open() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.isOpen = true
            defer { state.waiters.removeAll() }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }
}

private final class Counter: Sendable {
    private let count = OSAllocatedUnfairLock(initialState: 0)

    var value: Int {
        count.withLock { $0 }
    }

    func increment() {
        count.withLock { $0 += 1 }
    }
}

private struct AbortedStart: Error {}
private struct RefusedStart: Error {}

/// Locks the connect timeout. It cancelled `session.start()` on timeout, but
/// IPCamKit's `start()` ignores cancellation, so the task group kept waiting for it
/// and the 15 s limit wasn't enforced. The timeout now calls `abort` (the session's
/// `stop()`, which makes a running `start()` throw) and reports `TimeoutError`.
internal final class ConnectTimeoutTests: XCTestCase {
    private let shortTimeout: UInt64 = 50_000_000

    func testTimeoutAbortsAStartThatIgnoresCancellation() async {
        let gate = Gate()
        let aborts = Counter()
        // Safety net so a regression fails on the elapsed-time check instead of hanging.
        let safety = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            gate.open()
        }
        defer { safety.cancel() }

        let started = Date()
        do {
            _ = try await RTSPStreamPipeline.withConnectTimeout(
                nanoseconds: shortTimeout,
                start: { () async throws -> Int in
                    await gate.wait()
                    throw AbortedStart()
                },
                abort: {
                    aborts.increment()
                    gate.open()
                }
            )
            XCTFail("a start that never finishes must time out")
        } catch {
            XCTAssertTrue(error is RTSPStreamPipeline.TimeoutError, "expected TimeoutError, got \(error)")
        }

        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0, "the timeout must not wait for start()")
        XCTAssertEqual(aborts.value, 1)
    }

    func testStartThatFinishesInTimeIsReturnedWithoutAbort() async throws {
        let aborts = Counter()

        let value = try await RTSPStreamPipeline.withConnectTimeout(
            nanoseconds: 5_000_000_000,
            start: { 42 },
            abort: { aborts.increment() }
        )

        XCTAssertEqual(value, 42)
        XCTAssertEqual(aborts.value, 0)
    }

    func testStartErrorBeforeTheTimeoutIsPassedThrough() async {
        let aborts = Counter()

        do {
            _ = try await RTSPStreamPipeline.withConnectTimeout(
                nanoseconds: 5_000_000_000,
                start: { () async throws -> Int in throw RefusedStart() },
                abort: { aborts.increment() }
            )
            XCTFail("the start error must be thrown")
        } catch {
            XCTAssertTrue(error is RefusedStart, "expected the start error, got \(error)")
        }
        XCTAssertEqual(aborts.value, 0)
    }

    /// Cancelling the caller (a source switch) aborts a start that ignores
    /// cancellation, instead of leaving it connecting to the old camera.
    func testCancellingTheCallerAbortsStart() async {
        let gate = Gate()
        let aborts = Counter()
        let safety = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            gate.open()
        }
        defer { safety.cancel() }

        let connect = Task {
            try await RTSPStreamPipeline.withConnectTimeout(
                nanoseconds: 10_000_000_000,
                start: { () async throws -> Int in
                    await gate.wait()
                    throw AbortedStart()
                },
                abort: {
                    aborts.increment()
                    gate.open()
                }
            )
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        let started = Date()
        connect.cancel()
        let result = await connect.result

        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0, "cancellation must not wait for start()")
        XCTAssertEqual(aborts.value, 1)
        if case .success = result { XCTFail("a cancelled connect must not succeed") }
    }
}

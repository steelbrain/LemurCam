@testable import LemurCam
import XCTest

/// Guards the central `Tuning` table. These constants feed timeouts, retry/backoff
/// math, the jitter buffer, the sink queue, and network defaults across the app, so
/// a careless edit (a dropped zero in a nanosecond timeout, a backoff cap below the
/// base, a priming threshold above capacity) is a real regression. The values are
/// meant to be tuned, so this pins *invariants and contracts* — sign, scale, and the
/// relationships the consuming code relies on — rather than every exact number.
/// The two protocol port defaults are pinned exactly because they are not tunable.
internal final class TuningTests: XCTestCase {

    private let oneSecondNs: UInt64 = 1_000_000_000

    // MARK: - Timeouts (scale + sign)

    /// The `Ns` timeouts are consumed directly as `Task.sleep(nanoseconds:)` arguments,
    /// so they must be expressed in nanoseconds — pin the exact second-equivalents so a
    /// dropped or extra zero (millisecond/second-scale mistake) is caught.
    func testNanosecondTimeoutsAreInNanosecondScale() {
        XCTAssertEqual(Tuning.connectionTimeoutNs, 15 * oneSecondNs)
        XCTAssertEqual(Tuning.streamStallTimeoutNs, 10 * oneSecondNs)
    }

    func testSecondTimeoutsArePositive() {
        XCTAssertGreaterThan(Tuning.onvifRequestTimeout, 0)
        XCTAssertGreaterThan(Tuning.onvifReconnectTimeout, 0)
        // The reconnect flow wraps an HTTP fetch plus a discovery scan, so its budget
        // must be at least as large as a single request timeout.
        XCTAssertGreaterThanOrEqual(Tuning.onvifReconnectTimeout, Tuning.onvifRequestTimeout)
    }

    // MARK: - Retry / backoff

    func testRetryConstantsAreSane() {
        XCTAssertGreaterThanOrEqual(Tuning.maxSetupRetries, 1)
        XCTAssertGreaterThan(Tuning.setupRetryDelay, 0)
    }

    /// `scheduleRetry` computes `min(cap, base * pow(2, attempt))`. If the cap were
    /// below the base, even the first reconnect would be clamped under its intended
    /// delay, defeating the exponential backoff — so cap must not undercut base.
    func testReconnectBackoffCapNotBelowBase() {
        XCTAssertGreaterThan(Tuning.reconnectBackoffBase, 0)
        XCTAssertGreaterThanOrEqual(Tuning.reconnectBackoffCap, Tuning.reconnectBackoffBase)
    }

    // MARK: - Frame rates / intervals

    func testFrameRatesAndIntervalsArePositive() {
        XCTAssertGreaterThan(Tuning.placeholderFPS, 0)
        XCTAssertGreaterThan(Tuning.jitterBufferDrainFPS, 0)
        XCTAssertGreaterThan(Tuning.previewThrottleInterval, 0)
        XCTAssertGreaterThan(Tuning.fpsWindowDuration, 0)
        XCTAssertGreaterThan(Tuning.fpsUpdateInterval, 0)
        // The FPS estimate averages over a window; the window must outlast a single
        // readout interval or the estimate has too few samples to average.
        XCTAssertGreaterThanOrEqual(Tuning.fpsWindowDuration, Tuning.fpsUpdateInterval)
    }

    func testTimerLeewaysAreNonNegative() {
        XCTAssertGreaterThanOrEqual(Tuning.placeholderTimerLeewayMs, 0)
        XCTAssertGreaterThanOrEqual(Tuning.jitterBufferTimerLeewayMs, 0)
    }

    // MARK: - Jitter buffer

    /// The drain timer only starts once `buffer.count >= primingThreshold`, and the
    /// buffer evicts past `capacity`. A priming threshold above capacity could never be
    /// reached, so draining would never start — pin `1 <= priming <= capacity`.
    func testJitterBufferPrimingFitsWithinCapacity() {
        XCTAssertGreaterThanOrEqual(Tuning.jitterBufferPrimingThreshold, 1)
        XCTAssertLessThanOrEqual(Tuning.jitterBufferPrimingThreshold, Tuning.jitterBufferCapacity)
    }

    // MARK: - Extension sink buffers

    /// The sink stream starts once `sinkBuffersForStartup` buffers are queued, drawn
    /// from a pool of `sinkBufferQueueSize`. Needing more buffers than the queue can
    /// hold would deadlock startup, so the startup count must fit inside the queue.
    func testSinkBufferStartupFitsInQueue() {
        XCTAssertGreaterThanOrEqual(Tuning.sinkBuffersForStartup, 1)
        XCTAssertLessThanOrEqual(Tuning.sinkBuffersForStartup, Tuning.sinkBufferQueueSize)
    }

    // MARK: - Network defaults (protocol contracts, not tunable)

    func testDefaultPortsMatchProtocolStandards() {
        XCTAssertEqual(Tuning.defaultHTTPPort, 80)
        XCTAssertEqual(Tuning.defaultHTTPSPort, 443)
        for port in [Tuning.defaultHTTPPort, Tuning.defaultHTTPSPort] {
            XCTAssertTrue((1...65_535).contains(port), "port \(port) out of range")
        }
    }

    // MARK: - Settings window

    func testSettingsWindowIsLandscapeAndPositive() {
        XCTAssertGreaterThan(Tuning.settingsWindowWidth, 0)
        XCTAssertGreaterThan(Tuning.settingsWindowHeight, 0)
        // The window hosts a sidebar + detail pane, so it is wider than it is tall.
        XCTAssertGreaterThanOrEqual(Tuning.settingsWindowWidth, Tuning.settingsWindowHeight)
    }
}

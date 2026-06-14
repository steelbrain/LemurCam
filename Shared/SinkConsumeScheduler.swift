import Foundation

/// The next action the camera extension's sink stream should take after a
/// `consumeSampleBuffer(from:)` completion fires.
internal enum SinkConsumeAction: Equatable {
    /// The client errored or disconnected; stop the consume loop.
    case stop
    /// A buffer was delivered; re-arm immediately so frame bursts drain promptly.
    case resubscribeImmediately
    /// No buffer was ready; re-arm after this delay to avoid busy-polling.
    case resubscribeAfter(nanoseconds: UInt64)
}

/// Decides how the sink stream re-arms its pull after each completion.
///
/// The CMIO framework does not block an empty sink queue: when the producing app
/// has no frame ready it still fires the completion with no buffer. A naive
/// "always re-arm immediately" loop turns that into a busy XPC poll that pegs CPU
/// in both the extension and the app (the app is left replying to thousands of
/// empty `pullSample` requests per second). Re-arming immediately only when a
/// buffer was actually delivered — and otherwise waiting one frame interval —
/// caps empty polls at the frame rate while adding zero latency for real frames.
internal enum SinkConsumeScheduler {
    /// One frame interval in nanoseconds. `frameRate` is clamped to ≥ 1 so a bad
    /// or zero stored value can never divide by zero or spin without a delay.
    static func emptyPollDelayNanoseconds(frameRate: Int) -> UInt64 {
        let safeRate = max(1, frameRate)
        return UInt64(1_000_000_000 / safeRate)
    }

    /// Pure mapping from a `consumeSampleBuffer` completion to the next action.
    static func action(hasBuffer: Bool, hasError: Bool, frameRate: Int) -> SinkConsumeAction {
        if hasError { return .stop }
        if hasBuffer { return .resubscribeImmediately }
        return .resubscribeAfter(nanoseconds: emptyPollDelayNanoseconds(frameRate: frameRate))
    }
}

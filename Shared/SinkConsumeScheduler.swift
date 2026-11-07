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
/// buffer was actually delivered — and otherwise waiting a fraction of a frame
/// interval (`Tuning.sinkEmptyPollsPerFrame`) — caps empty polls at a small multiple
/// of the frame rate. A frame waits at most that long in the app's queue, which the
/// source stream's pacing absorbs; a wait of a whole frame at 60 fps did not leave
/// it enough room.
internal enum SinkConsumeScheduler {
    /// One frame interval at `frameRate`, divided by `Tuning.sinkEmptyPollsPerFrame`,
    /// in nanoseconds. Both are clamped to ≥ 1 so a bad or zero value can never
    /// divide by zero or spin without a delay.
    static func emptyPollDelayNanoseconds(frameRate: Int) -> UInt64 {
        let pollsPerSecond = max(1, frameRate) * max(1, Tuning.sinkEmptyPollsPerFrame)
        return UInt64(1_000_000_000 / pollsPerSecond)
    }

    /// Pure mapping from a `consumeSampleBuffer` completion to the next action.
    static func action(hasBuffer: Bool, hasError: Bool, frameRate: Int) -> SinkConsumeAction {
        if hasError { return .stop }
        if hasBuffer { return .resubscribeImmediately }
        return .resubscribeAfter(nanoseconds: emptyPollDelayNanoseconds(frameRate: frameRate))
    }
}

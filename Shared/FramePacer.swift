/// Decides which frames from the app the camera extension sends to its
/// consumers, so the camera never runs faster than its active frame rate. The
/// app delivers frames at the camera's own rate, which can be above the rate an
/// app asked for (a 60 fps camera at 30 fps). Pure, CMIO-free and unit-tested
/// through the app module; `ExtensionDeviceRuntime` keeps one per source stream.
///
/// It keeps a credit of frames: earned at the active rate, spent one per frame
/// sent, and capped at `Tuning.framePacingBurst`. A faster camera is thinned to the
/// active rate, and after a stall at most that many frames go out back to back. A
/// camera at the active rate keeps every frame although its frames reach the
/// extension with jitter: one can come late (the extension polls the app for
/// frames, and they cross two processes) and the next right behind it, and the
/// credit pays for both. A schedule of fixed slots did not: each late frame moved
/// the slots later for good, until a frame on time counted as early and was dropped.
internal struct FramePacer: Equatable, Sendable {
    /// Frames that may go out, as of `lastNanoseconds`. Starts full.
    private(set) var credit = Self.burst
    /// When `credit` was last brought up to date, in host-clock nanoseconds; nil
    /// until the first frame.
    private(set) var lastNanoseconds: UInt64?

    /// Whether to send a frame that arrives at `now` (host-clock nanoseconds) when
    /// frames are `duration` nanoseconds apart. A zero duration paces nothing.
    mutating func admit(atNanoseconds now: UInt64, frameDurationNanoseconds duration: UInt64) -> Bool {
        guard duration > 0 else { return true }
        if let last = lastNanoseconds, now > last {
            credit = min(Self.burst, credit + Double(now - last) / Double(duration))
        }
        lastNanoseconds = max(lastNanoseconds ?? now, now)
        // A hair under one frame still counts, so floating-point rounding on a camera
        // exactly at the active rate never costs a frame.
        guard credit >= 1 - 1e-9 else { return false }
        credit -= 1
        return true
    }

    /// Start over with full credit, so the next frame is sent whenever it comes.
    mutating func reset() {
        credit = Self.burst
        lastNanoseconds = nil
    }

    /// `Tuning.framePacingBurst`, at least one frame.
    private static var burst: Double {
        max(Tuning.framePacingBurst, 1)
    }
}

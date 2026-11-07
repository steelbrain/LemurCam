import Foundation

/// The jitter buffer's sizes at one drain rate. The buffer is sized in time, not
/// frames: `Tuning.jitterBufferCapacity` and `Tuning.jitterBufferPrimingThreshold`
/// are frame counts at `Tuning.jitterBufferDefaultDrainFPS`, and at another rate they
/// scale with it. A 60 fps camera gets the same ~530 ms to ride out a keyframe stall
/// and the same ~200 ms start-up cushion as a 30 fps one; at the old fixed 30 fps
/// drain, a 60 fps camera filled the buffer, lost every other frame to its capacity
/// and ran half a second behind.
internal struct JitterBufferSizing: Equatable, Sendable {
    /// Frames drained per second.
    let drainFPS: Double
    /// Frames held at most; the oldest is dropped to make room.
    let capacity: Int
    /// Frames to hold before draining starts, and the depth the catch-up returns to.
    let primingThreshold: Int
    /// Drain ticks per catch-up window (`JitterDepthTracker`).
    let catchUpWindowTicks: Int

    /// The sizes at `drainFPS`, held between `Tuning.jitterBufferMinDrainFPS` and
    /// `Tuning.jitterBufferMaxDrainFPS` (the default rate when it isn't a number).
    /// `catchUpWindowTicks` overrides the window, for tests.
    init(drainFPS requested: Double, catchUpWindowTicks override: Int? = nil) {
        let fps = Self.clamped(requested)
        let scale = fps / Tuning.jitterBufferDefaultDrainFPS
        let priming = max(1, Int((Double(Tuning.jitterBufferPrimingThreshold) * scale).rounded()))
        drainFPS = fps
        primingThreshold = priming
        capacity = max(priming + 1, Int((Double(Tuning.jitterBufferCapacity) * scale).rounded()))
        catchUpWindowTicks = max(1, override ?? Int((Tuning.jitterBufferCatchUpWindow * fps).rounded()))
    }

    /// Seconds between drain ticks.
    var drainInterval: TimeInterval {
        1 / drainFPS
    }

    static func clamped(_ fps: Double) -> Double {
        guard fps.isFinite else { return Tuning.jitterBufferDefaultDrainFPS }
        return min(max(fps, Tuning.jitterBufferMinDrainFPS), Tuning.jitterBufferMaxDrainFPS)
    }
}

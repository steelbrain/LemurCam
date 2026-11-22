import Foundation

/// The jitter buffer's sizes at one drain rate and Video Buffer setting. The buffer
/// is sized in time, not frames: `Tuning.jitterBufferCapacity` and
/// `Tuning.jitterBufferPrimingThreshold` are frame counts at
/// `Tuning.jitterBufferDefaultDrainFPS` and the default setting (200 ms), and they
/// scale with the drain rate and with the setting. A 60 fps camera gets the same
/// ~530 ms to ride out a keyframe stall and the same ~200 ms start-up cushion as a
/// 30 fps one; at the old fixed 30 fps drain, a 60 fps camera filled the buffer,
/// lost every other frame to its capacity and ran half a second behind. At 100 ms
/// both windows are half as long. With the setting off there is no buffer: each
/// frame goes on as it is decoded (`passesThrough`), and only the newest is held.
internal struct JitterBufferSizing: Equatable, Sendable {
    /// Frames drained per second.
    let drainFPS: Double
    /// The Video Buffer setting the sizes are for.
    let videoBuffer: VideoBufferSetting
    /// Frames held at most; the oldest is dropped to make room.
    let capacity: Int
    /// Frames to hold before draining starts, and the depth the catch-up returns to.
    let primingThreshold: Int
    /// Drain ticks per catch-up window (`JitterDepthTracker`).
    let catchUpWindowTicks: Int

    /// The sizes at `drainFPS`, held between `Tuning.jitterBufferMinDrainFPS` and
    /// `Tuning.jitterBufferMaxDrainFPS` (the default rate when it isn't a number), for
    /// `videoBuffer`. `catchUpWindowTicks` overrides the window, for tests.
    init(
        drainFPS requested: Double,
        videoBuffer: VideoBufferSetting = .defaultValue,
        catchUpWindowTicks override: Int? = nil
    ) {
        let fps = Self.clamped(requested)
        // Exactly 1 at the default setting, so its counts are the tuned ones.
        let delayScale = Double(videoBuffer.milliseconds) / Double(VideoBufferSetting.defaultValue.milliseconds)
        let scale = fps / Tuning.jitterBufferDefaultDrainFPS * delayScale
        drainFPS = fps
        self.videoBuffer = videoBuffer
        catchUpWindowTicks = max(1, override ?? Int((Tuning.jitterBufferCatchUpWindow * fps).rounded()))
        guard videoBuffer != .off else {
            primingThreshold = 1
            capacity = 1
            return
        }
        let priming = max(1, Int((Double(Tuning.jitterBufferPrimingThreshold) * scale).rounded()))
        primingThreshold = priming
        capacity = max(priming + 1, Int((Double(Tuning.jitterBufferCapacity) * scale).rounded()))
    }

    /// Frames skip the buffer: each one is sent on as soon as it is decoded, and none
    /// is sent again while the camera sends nothing.
    var passesThrough: Bool {
        videoBuffer == .off
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

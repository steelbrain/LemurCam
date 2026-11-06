/// Decides which frames from the app the camera extension sends to its
/// consumers, so the camera never runs faster than its active frame rate. The
/// app delivers frames at the camera's own rate, which can be above the rate an
/// app asked for (a 60 fps camera at 30 fps). Pure, CMIO-free and unit-tested
/// through the app module; `ExtensionDeviceRuntime` keeps one per source stream.
///
/// Frames are held to a schedule, one slot per frame duration. A frame is sent
/// when it arrives no earlier than its slot, less `Tuning.framePacingTolerance`
/// of a duration, so a camera at the active rate isn't halved by its jitter. A
/// frame sent late doesn't let the next ones catch up in a burst: the next slot
/// is at least a duration, less the tolerance, after it.
internal struct FramePacer: Equatable, Sendable {
    /// When the next frame is due, in host-clock nanoseconds; nil until a frame is sent.
    private(set) var nextDueNanoseconds: UInt64?

    /// Whether to send a frame that arrives at `now` (host-clock nanoseconds) when
    /// frames are `duration` nanoseconds apart. A sent frame books the next slot.
    /// A zero duration paces nothing.
    mutating func admit(atNanoseconds now: UInt64, frameDurationNanoseconds duration: UInt64) -> Bool {
        guard duration > 0 else { return true }
        // At most half a frame, which also keeps the product in range of UInt64.
        let tolerance = min(max(Tuning.framePacingTolerance, 0), 0.5)
        let slack = UInt64(Double(duration) * tolerance)
        if let due = nextDueNanoseconds, now.saturatingAdd(slack) < due {
            return false
        }
        let onSchedule = (nextDueNanoseconds ?? now).saturatingAdd(duration)
        let afterThisFrame = now.saturatingAdd(duration - slack)
        nextDueNanoseconds = max(onSchedule, afterThisFrame)
        return true
    }

    /// Forget the schedule, so the next frame is sent whenever it comes.
    mutating func reset() {
        nextDueNanoseconds = nil
    }
}

private extension UInt64 {
    func saturatingAdd(_ other: UInt64) -> UInt64 {
        let (sum, overflow) = addingReportingOverflow(other)
        return overflow ? .max : sum
    }
}

/// Measures a camera's frame rate from its video frames' timestamps, which IPCamKit
/// derives from the RTP timestamp the camera gives each frame. The jitter buffer
/// drains at this rate. Arrival times would not do: a camera stalls while it encodes
/// a keyframe and then sends a burst, and the network adds its own jitter.
///
/// Over the last `Tuning.frameRateWindowFrames` frames, in time order (so frames
/// sent out of order, B-frames, don't matter), the rate is the number of frame
/// intervals divided by the time they span. A gap counts as as many intervals as
/// typical gaps fit in it, so a lost frame (a double gap) doesn't lower the rate; the
/// typical gap is the mean of the middle half of the gaps, so neither lost frames nor
/// a camera that stamps frames a little early and late skews it. Pure, for one
/// connection; the pipeline keeps one per stream.
internal struct VideoFrameRateEstimator: Sendable {
    /// Timestamps (seconds) of the frames in the window, in arrival order.
    private var timestamps: [Double] = []
    /// The rate last reported; nil until there is one.
    private(set) var reportedRate: Double?

    /// Record a video frame's timestamp, in seconds. Returns the camera's frame rate
    /// when it is first known (after `Tuning.frameRateMinimumFrames` frames), and
    /// again whenever it moves by more than `Tuning.frameRateChangeThreshold`, or by
    /// more than `Tuning.frameRateSettledChangeThreshold` once a whole window of
    /// frames refines it; nil otherwise.
    mutating func record(timestamp: Double) -> Double? {
        guard timestamp.isFinite else { return nil }
        if let last = timestamps.last, abs(timestamp - last) > Tuning.frameRateDiscontinuity {
            timestamps.removeAll(keepingCapacity: true)
        }
        timestamps.append(timestamp)
        if timestamps.count > Tuning.frameRateWindowFrames {
            timestamps.removeFirst(timestamps.count - Tuning.frameRateWindowFrames)
        }
        guard timestamps.count >= Tuning.frameRateMinimumFrames, let rate = Self.rate(of: timestamps) else {
            return nil
        }
        let threshold = timestamps.count < Tuning.frameRateWindowFrames
            ? Tuning.frameRateChangeThreshold
            : Tuning.frameRateSettledChangeThreshold
        if let reported = reportedRate, abs(rate - reported) <= reported * threshold {
            return nil
        }
        reportedRate = rate
        return rate
    }

    /// The frame rate of frames taken at `timestamps` (seconds, any order), rounded
    /// to a whole number when within 2% of one (29.97 is reported as 30). Nil without
    /// two distinct timestamps.
    static func rate(of timestamps: [Double]) -> Double? {
        let sorted = timestamps.sorted()
        let gaps = zip(sorted.dropFirst(), sorted).map { $0 - $1 }.filter { $0 > 0 }
        guard let first = sorted.first, let last = sorted.last, last > first, !gaps.isEmpty else { return nil }
        let ordered = gaps.sorted()
        let quarter = ordered.count / 4
        let middle = ordered[quarter..<(ordered.count - quarter)]
        let typicalGap = middle.reduce(0, +) / Double(middle.count)
        let intervals = gaps.reduce(0) { $0 + max(1, ($1 / typicalGap).rounded()) }
        let rate = intervals / (last - first)
        guard rate.isFinite, rate > 0 else { return nil }
        let whole = rate.rounded()
        return whole > 0 && abs(rate - whole) <= whole * 0.02 ? whole : rate
    }
}

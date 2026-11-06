import CoreMedia

/// Converts `CMTime` values to the `hostTimeInNanoseconds` that the CMIO extension
/// APIs take. `UInt64(_:)` traps on NaN, infinite, negative or out-of-range
/// input, and a sample buffer's timestamp can be invalid or indefinite, so every
/// conversion goes through here instead of `UInt64(time.seconds * 1e9)`.
internal enum HostTimeNanoseconds {
    /// `time` in nanoseconds, or nil when it is not a finite, non-negative number
    /// that fits in `UInt64` (invalid, indefinite, ±infinity, NaN, negative, huge).
    static func nanoseconds(_ time: CMTime) -> UInt64? {
        guard time.isNumeric else { return nil }
        let nanoseconds = time.seconds * Double(NSEC_PER_SEC)
        // Double(UInt64.max) rounds up to 2^64, so `<` keeps the conversion in range.
        guard nanoseconds.isFinite, nanoseconds >= 0, nanoseconds < Double(UInt64.max) else {
            return nil
        }
        return UInt64(nanoseconds)
    }

    /// `time` in nanoseconds, or the current host time when `time` can't be
    /// converted. `hostNow` is injectable for tests; 0 only if it fails as well.
    static func nanoseconds(_ time: CMTime, fallback hostNow: () -> CMTime) -> UInt64 {
        nanoseconds(time) ?? nanoseconds(hostNow()) ?? 0
    }

    /// `time` in nanoseconds, or the current host time when `time` can't be converted.
    static func nanosecondsOrNow(_ time: CMTime) -> UInt64 {
        nanoseconds(time, fallback: currentHostTime)
    }

    /// The current host time in nanoseconds.
    static func now() -> UInt64 {
        nanoseconds(currentHostTime()) ?? 0
    }

    private static func currentHostTime() -> CMTime {
        CMClockGetTime(CMClockGetHostTimeClock())
    }
}

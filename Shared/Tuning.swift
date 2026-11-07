import Foundation

/// Centralized runtime tuning constants. Behavioral parameters that affect
/// timeouts, retry logic, frame rates, and network defaults live here so
/// they can be reviewed and adjusted in one place.
internal enum Tuning {

    // MARK: - Timeouts

    /// RTSP connection timeout (nanoseconds).
    static let connectionTimeoutNs: UInt64 = 15_000_000_000

    /// Stream-stall watchdog timeout (nanoseconds). Also used by BootSanityChecker.
    static let streamStallTimeoutNs: UInt64 = 10_000_000_000

    /// Video-decode stall timeout (nanoseconds): how long after a keyframe arrives the
    /// decoder may go without producing a picture before the stream is reconnected.
    /// A working decoder outputs a keyframe within milliseconds, so this only catches
    /// a failed decoder session or format description. Waiting for a keyframe (at
    /// stream start or after packet loss) doesn't count, whatever the keyframe interval.
    static let videoDecodeStallTimeoutNs: UInt64 = 20_000_000_000

    /// ONVIF HTTP request timeout (seconds): how long one request may go without
    /// receiving anything, connecting included. A request to an address where nothing
    /// answers fails after this long.
    static let onvifRequestTimeout: TimeInterval = 10

    /// Longest one stream-URI fetch in the ONVIF reconnection flow may take (seconds),
    /// counting the clock and capabilities requests before GetStreamUri. Longer than
    /// one request timeout, so a fetch from an address where nothing answers fails on
    /// its own and leads to a WS-Discovery scan.
    static let onvifReconnectFetchTimeout: TimeInterval = 15

    /// How long a WS-Discovery scan collects replies (seconds).
    static let onvifDiscoveryScanDuration: TimeInterval = 5

    /// How long a WS-Discovery scan waits for one reply before it checks its deadline
    /// again (seconds). A scan can run this much longer than its duration.
    static let onvifDiscoveryReceiveTimeout: TimeInterval = 1

    /// Overall timeout for the ONVIF reconnection flow (seconds). It covers each step
    /// at its own limit: the fetch from the saved address, a WS-Discovery scan, and
    /// the fetch from the address the scan found, plus a second for the work between.
    static let onvifReconnectTimeout: TimeInterval = onvifReconnectFetchTimeout
        + onvifDiscoveryScanDuration + onvifDiscoveryReceiveTimeout
        + onvifReconnectFetchTimeout + 1

    // MARK: - Retry

    /// Maximum attempts to find the virtual camera stream during setup.
    static let maxSetupRetries = 10

    /// Delay between setup retries (seconds).
    static let setupRetryDelay: TimeInterval = 1.0

    /// Exponential backoff base for RTSP reconnect (seconds).
    static let reconnectBackoffBase: TimeInterval = 2.0

    /// Maximum reconnect delay cap (seconds).
    static let reconnectBackoffCap: TimeInterval = 30.0

    // MARK: - Placeholder

    /// Frame rate for the static placeholder image (fps).
    static let placeholderFPS: Double = 5.0

    /// Timer leeway for the placeholder generator (milliseconds).
    static let placeholderTimerLeewayMs = 10

    // MARK: - Preview

    /// Minimum interval between preview frame updates (seconds). Caps preview at ~5 fps.
    static let previewThrottleInterval: TimeInterval = 0.2

    /// Maximum height (in pixels) of a rendered preview frame. The preview is shown at
    /// 180 points (≤360px at 2× Retina), so frames are downscaled to this before the
    /// CGImage readback — rendering full source resolution (up to 4K) wastes a large
    /// GPU→CPU copy per frame with no visible benefit at display size.
    static let previewRenderMaxHeight: CGFloat = 360

    /// Sliding window for FPS estimation (seconds).
    static let fpsWindowDuration: TimeInterval = 2.0

    /// Minimum interval between FPS readout updates (seconds).
    static let fpsUpdateInterval: TimeInterval = 1.0

    // MARK: - Network Defaults

    /// Default HTTP port for ONVIF devices.
    static let defaultHTTPPort = 80

    /// Default HTTPS port for ONVIF devices.
    static let defaultHTTPSPort = 443

    // MARK: - Jitter Buffer

    /// The jitter buffer's drain rate (fps) until the camera's own frame rate is
    /// known. The buffer then drains at the camera's rate (`VideoFrameRateEstimator`),
    /// between `jitterBufferMinDrainFPS` and `jitterBufferMaxDrainFPS`.
    static let jitterBufferDefaultDrainFPS: Double = 30.0

    /// The fastest the jitter buffer drains: the fastest frame rate the virtual camera
    /// offers (`StreamFormatTable.fastestFrameRate`). A faster camera is drained at
    /// this rate.
    static let jitterBufferMaxDrainFPS: Double = 60.0

    /// The slowest the jitter buffer drains. A slower camera's last frame is sent again
    /// between its frames.
    static let jitterBufferMinDrainFPS: Double = 1.0

    /// Maximum frames the jitter buffer holds at `jitterBufferDefaultDrainFPS` (~530ms).
    /// Sized to absorb the ~300-400ms keyframe-encoding stalls IP cameras exhibit
    /// without dropping the catch-up burst. At another drain rate it scales with the
    /// rate, so the window stays the same length in time (`JitterBufferSizing`).
    static let jitterBufferCapacity: Int = 16

    /// Frames to accumulate before starting the drain timer, at
    /// `jitterBufferDefaultDrainFPS` (~200ms); scaled with the drain rate like
    /// `jitterBufferCapacity`.
    static let jitterBufferPrimingThreshold: Int = 6

    /// Window (seconds) over which the jitter buffer watches its lowest depth. If the
    /// depth never fell to the priming level within a window, the frames above it
    /// were never needed and the oldest are dropped down to that level, so a burst
    /// doesn't raise latency for good. A window must span at least one keyframe
    /// interval: a stall that recurs less often looks like unneeded cushion and costs
    /// one stutter per window.
    static let jitterBufferCatchUpWindow: TimeInterval = 10

    /// Timer leeway for the jitter buffer drain timer (milliseconds).
    static let jitterBufferTimerLeewayMs: Int = 2

    // MARK: - Camera Frame Rate

    /// How many recent video frames the camera's frame rate is measured over: one
    /// second at 60 fps, two at 30.
    static let frameRateWindowFrames = 60

    /// Frames needed before the camera's frame rate is first reported. Five gaps
    /// between them, so a single lost frame doesn't skew the median gap. At 30 fps
    /// the rate is known by the time the jitter buffer primes.
    static let frameRateMinimumFrames = 6

    /// How much (as a fraction) the measured frame rate must move from the one last
    /// reported before it is reported again, while fewer than `frameRateWindowFrames`
    /// frames are measured: a few frames from a camera that stamps them a little early
    /// and late can be a few percent off, and the drain timer isn't re-armed for that.
    static let frameRateChangeThreshold = 0.05

    /// The same, once a whole window of frames is measured: the rate is then within a
    /// fraction of a percent, so a first estimate a few percent off is corrected, and a
    /// drain rate off by more than this would repeat or drop a frame every few seconds.
    static let frameRateSettledChangeThreshold = 0.01

    /// A gap (seconds) between two frames' timestamps beyond which the measurement
    /// starts over: the camera restarted its clock, or the stream was interrupted.
    static let frameRateDiscontinuity: Double = 5

    // MARK: - Extension Buffers

    /// Number of sample buffers in the CMIO sink queue.
    static let sinkBufferQueueSize = 4

    /// Minimum buffers required before the sink stream starts.
    static let sinkBuffersForStartup = 1

    // MARK: - Extension Formats

    /// How far (as a fraction of the duration) a frame duration a client sets may be
    /// from a valid one and still count as it: 1/29.97 s is 30 fps.
    static let frameDurationMatchTolerance = 0.02

    /// How early (as a fraction of the frame duration) the extension still sends a
    /// frame. A camera at the active rate delivers with some jitter; without this
    /// slack, every frame that came a little early would be dropped and a 30 fps
    /// camera at 30 fps would come out near 15.
    static let framePacingTolerance = 0.25

    // MARK: - Settings Window

    /// Settings window size. Wider than a single pane to fit the sidebar layout.
    static let settingsWindowWidth: CGFloat = 720
    static let settingsWindowHeight: CGFloat = 480

    // MARK: - Setup Window

    /// Guided setup wizard size. The window is fixed (non-resizable); these are
    /// shared by the `NSWindow` and its SwiftUI root so the two never drift. The
    /// height is sized to the tallest step so the longest content fits without
    /// leaving the dead space a one-size-fits-all tall window would.
    static let setupWindowWidth: CGFloat = 480
    static let setupWindowHeight: CGFloat = 500

    // MARK: - Launch Nudge Banner

    /// Width of the proactive launch banner shown when an upgrade left the camera
    /// needing a restart. Shared by the SwiftUI content and the hosting `NSWindow`.
    static let launchNudgeWindowWidth: CGFloat = 360

    // MARK: - Help & About Windows

    /// Help window size. Tall enough to read a few topics at once; the content
    /// scrolls past it. Shared by the `NSWindow` and its SwiftUI root.
    static let helpWindowWidth: CGFloat = 460
    static let helpWindowHeight: CGFloat = 560

    /// About window size — a compact card with the icon, version, and links.
    static let aboutWindowWidth: CGFloat = 340
    static let aboutWindowHeight: CGFloat = 320
}

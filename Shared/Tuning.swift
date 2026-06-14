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

    /// ONVIF HTTP request timeout (seconds).
    static let onvifRequestTimeout: TimeInterval = 10

    /// Overall timeout for the ONVIF reconnection flow (seconds).
    /// Covers: initial fetch + WS-Discovery scan + re-fetch at new address.
    static let onvifReconnectTimeout: TimeInterval = 15

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

    /// Fixed drain rate for the jitter buffer (fps). Caps the virtual camera's
    /// output frame rate; the capacity/priming below are scaled to keep the same
    /// smoothing/priming *time* windows at this rate.
    static let jitterBufferDrainFPS: Double = 30.0

    /// Maximum frames the jitter buffer can hold (~530ms at 30fps). Sized to absorb
    /// the ~300-400ms keyframe-encoding stalls IP cameras exhibit without dropping
    /// the catch-up burst.
    static let jitterBufferCapacity: Int = 16

    /// Frames to accumulate before starting the drain timer (~200ms at 30fps).
    static let jitterBufferPrimingThreshold: Int = 6

    /// Timer leeway for the jitter buffer drain timer (milliseconds).
    static let jitterBufferTimerLeewayMs: Int = 2

    // MARK: - Extension Buffers

    /// Number of sample buffers in the CMIO sink queue.
    static let sinkBufferQueueSize = 4

    /// Minimum buffers required before the sink stream starts.
    static let sinkBuffersForStartup = 1

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

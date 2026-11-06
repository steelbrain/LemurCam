import Foundation

/// Pure, CMIO-free bookkeeping for the camera extension's `ExtensionDeviceRuntime`:
/// how many apps are consuming the source stream, whether the placeholder timer
/// runs, and whether the app is feeding the sink. Lives in `Shared/` so it is
/// unit-tested through the app module; the runtime keeps the CMIO stream, the
/// placeholder buffer and the dispatch timer.
internal struct ExtensionStreamingState: Equatable, Sendable {
    /// Result of a source-stream consumer stopping.
    internal struct StopOutcome: Equatable, Sendable {
        /// Whether at least one consumer is still counted.
        let hasConsumers: Bool
        /// Whether the caller must cancel the placeholder timer now.
        let cancelPlaceholderTimer: Bool
    }

    private(set) var consumerCount: UInt32 = 0
    private(set) var placeholderTimerRunning = false
    private(set) var isSinking = false

    /// Live sink frames reach the source stream only while a consumer is counted.
    var forwardsSinkFrames: Bool { consumerCount > 0 }

    /// The placeholder is shown only while the app isn't feeding real frames.
    var emitsPlaceholder: Bool { !isSinking }

    /// A source-stream consumer started. It is always counted, with or without a
    /// placeholder: an uncounted consumer made `forwardSinkFrames` drop every live
    /// frame when the placeholder failed to render. Returns whether the caller
    /// should create and start the placeholder timer, which happens only when a
    /// placeholder exists and the timer isn't already running.
    mutating func consumerStarted(hasPlaceholder: Bool) -> Bool {
        if consumerCount < .max { consumerCount += 1 }
        guard hasPlaceholder, !placeholderTimerRunning else { return false }
        placeholderTimerRunning = true
        return true
    }

    /// A source-stream consumer stopped. The last one out (or an unbalanced stop)
    /// resets the count to zero and stops the placeholder timer if it runs.
    mutating func consumerStopped() -> StopOutcome {
        if consumerCount > 1 {
            consumerCount -= 1
            return StopOutcome(hasConsumers: true, cancelPlaceholderTimer: false)
        }
        consumerCount = 0
        let cancelTimer = placeholderTimerRunning
        placeholderTimerRunning = false
        return StopOutcome(hasConsumers: false, cancelPlaceholderTimer: cancelTimer)
    }

    mutating func startSinking() {
        isSinking = true
    }

    /// Returns whether sinking was active (so the caller only tears down once).
    mutating func stopSinking() -> Bool {
        guard isSinking else { return false }
        isSinking = false
        return true
    }
}

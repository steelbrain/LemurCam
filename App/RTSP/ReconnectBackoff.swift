import Foundation
import os

/// Reconnect delays for the active camera, doubling from
/// `Tuning.reconnectBackoffBase` up to `Tuning.reconnectBackoffCap`. Failures count
/// until a stream decodes a frame, not merely until it connects: a camera that
/// accepts PLAY and then drops, or a stream that never decodes, used to reset the
/// count on every connect and so retry at the base delay forever. Failures count
/// per source, so a newly selected or edited source starts from the base delay.
internal struct ReconnectBackoff {
    /// The source, and the edit of it, that failures are counted for.
    internal struct Source: Equatable {
        let id: UUID?
        let updatedAt: Date?
    }

    /// Failures counted since the last decoded frame or source change.
    private(set) var failures = 0
    private var source: Source?

    /// Count a failure of `source` and return how long to wait before reconnecting.
    mutating func delayAfterFailure(of source: Source) -> TimeInterval {
        if source != self.source {
            self.source = source
            failures = 0
        }
        let delay = min(Tuning.reconnectBackoffCap, Tuning.reconnectBackoffBase * pow(2.0, Double(failures)))
        failures += 1
        return delay
    }

    /// The stream decoded a frame, so it works: the next failure starts over.
    mutating func reset() {
        failures = 0
    }
}

/// Armed when a stream reaches `.streaming` and taken by the first frame it
/// decodes, which is what proves a stream healthy. Frames arrive on VideoToolbox's
/// output thread while the state changes land on the main actor, hence the lock.
internal final class FirstDecodedFrameSignal: Sendable {
    private let armed = OSAllocatedUnfairLock(initialState: false)

    func arm() {
        armed.withLock { $0 = true }
    }

    func disarm() {
        armed.withLock { $0 = false }
    }

    /// Whether this is the first frame since `arm()`. Disarms.
    func take() -> Bool {
        armed.withLock { isArmed in
            defer { isArmed = false }
            return isArmed
        }
    }
}

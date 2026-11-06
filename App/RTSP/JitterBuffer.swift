import CoreVideo
import Foundation
import os

/// Thread-safe jitter buffer that smooths bursty frame delivery from IP cameras.
///
/// IP cameras stall for ~300-400ms during keyframe encoding, creating visible
/// stutters. This buffer accumulates frames during bursts and drains them at a
/// steady rate, absorbing timing gaps.
internal final class JitterBuffer: Sendable {
    private struct State: Sendable {
        var buffer: [SendablePixelBuffer] = []
        var lastFrame: SendablePixelBuffer?
        var drainTimer: DispatchSourceTimer?
        var isPrimed = false
        var depthTracker: JitterDepthTracker
    }

    private let state: OSAllocatedUnfairLock<State>

    private let drainQueue = DispatchQueue(
        label: "com.steelbrain.LemurCam.jitterDrain", qos: .userInteractive
    )
    private let onDrain: @Sendable (CVPixelBuffer) -> Void

    /// - Parameter catchUpWindowTicks: drain ticks per catch-up window (see
    ///   `JitterDepthTracker`); tests pass a short one.
    init(
        catchUpWindowTicks: Int = Int(Tuning.jitterBufferCatchUpWindow * Tuning.jitterBufferDrainFPS),
        onDrain: @escaping @Sendable (CVPixelBuffer) -> Void
    ) {
        let tracker = JitterDepthTracker(
            windowTicks: catchUpWindowTicks, targetDepth: Tuning.jitterBufferPrimingThreshold
        )
        self.state = OSAllocatedUnfairLock(initialState: State(depthTracker: tracker))
        self.onDrain = onDrain
    }

    deinit {
        state.withLock {
            $0.drainTimer?.cancel()
            $0.drainTimer = nil
        }
    }

    /// Enqueue a decoded frame. Called from the VTDecompression callback thread.
    func enqueue(_ pixelBuffer: CVPixelBuffer) {
        let frame = SendablePixelBuffer(pixelBuffer)
        state.withLock {
            if $0.buffer.count >= Tuning.jitterBufferCapacity {
                $0.buffer.removeFirst()
            }
            $0.buffer.append(frame)

            // Prime and arm the drain timer while still holding the lock so the timer
            // mutation is serialized with `reset()`. `enqueue` runs on the decode thread
            // and `reset()` on the main actor; both touch `drainTimer`, so the priming
            // decision and the timer start must be atomic with respect to a reset that
            // could otherwise clear `isPrimed`/`drainTimer` in between.
            if !$0.isPrimed && $0.buffer.count >= Tuning.jitterBufferPrimingThreshold {
                $0.isPrimed = true
                $0.drainTimer?.cancel()
                $0.drainTimer = makeDrainTimer()
            }
        }
    }

    /// Clear the buffer and stop draining. Called on stream stop/reconnect.
    func reset() {
        state.withLock {
            $0.drainTimer?.cancel()
            $0.drainTimer = nil
            $0.buffer.removeAll()
            $0.lastFrame = nil
            $0.isPrimed = false
            $0.depthTracker.reset()
        }
    }

    // MARK: - Private

    private func makeDrainTimer() -> DispatchSourceTimer {
        let interval = 1.0 / Tuning.jitterBufferDrainFPS
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: drainQueue)
        timer.schedule(
            deadline: .now() + interval,
            repeating: interval,
            leeway: .milliseconds(Tuning.jitterBufferTimerLeewayMs)
        )
        timer.setEventHandler { [weak self] in self?.drain() }
        timer.resume()
        return timer
    }

    private func drain() {
        let frame: SendablePixelBuffer? = state.withLock {
            let next = $0.buffer.first
            if next != nil {
                $0.buffer.removeFirst()
            }
            // Catch up: drop the oldest frames a whole window showed were never needed.
            let excess = $0.depthTracker.recordDrain(depth: $0.buffer.count)
            if excess > 0 {
                $0.buffer.removeFirst(excess)
            }
            if let next {
                $0.lastFrame = next
                return next
            }
            return $0.lastFrame
        }

        if let frame {
            frame.withValue(onDrain)
        }
    }
}

/// Decides when the jitter buffer can drop frames it does not need. The buffer drains
/// one frame per tick while a camera at the drain rate delivers one per tick, so after
/// a burst (a network hiccup, a long stall) it stays as deep as the burst left it and
/// the extra latency, up to the full capacity, never goes away. The tracker records
/// the lowest depth over a window of drain ticks. If that lowest depth stayed above
/// `targetDepth`, the frames above it were never needed to ride out a stall, so the
/// excess is dropped. A window in which the depth fell to the target or below (a
/// keyframe stall drained it) drops nothing.
internal struct JitterDepthTracker: Sendable {
    let windowTicks: Int
    let targetDepth: Int
    private var ticks = 0
    private var lowestDepth = Int.max

    init(windowTicks: Int, targetDepth: Int) {
        self.windowTicks = max(1, windowTicks)
        self.targetDepth = targetDepth
    }

    /// Record the depth left after one drain tick. Returns how many of the oldest
    /// frames to drop now: non-zero only at the end of a window.
    mutating func recordDrain(depth: Int) -> Int {
        lowestDepth = min(lowestDepth, depth)
        ticks += 1
        guard ticks >= windowTicks else { return 0 }
        let excess = max(0, lowestDepth - targetDepth)
        reset()
        return excess
    }

    mutating func reset() {
        ticks = 0
        lowestDepth = .max
    }
}

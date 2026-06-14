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
    }

    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    private let drainQueue = DispatchQueue(
        label: "com.steelbrain.LemurCam.jitterDrain", qos: .userInteractive
    )
    private let onDrain: @Sendable (CVPixelBuffer) -> Void

    init(onDrain: @escaping @Sendable (CVPixelBuffer) -> Void) {
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
            if let next = $0.buffer.first {
                $0.buffer.removeFirst()
                $0.lastFrame = next
                return next
            } else {
                return $0.lastFrame
            }
        }

        if let frame {
            frame.withValue(onDrain)
        }
    }
}

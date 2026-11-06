import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation
import os

/// Lock-protected runtime state for `ExtensionDeviceSource`. The counting and
/// sink/placeholder decisions live in the pure `ExtensionStreamingState` (Shared/,
/// unit-tested); this type adds the CMIO stream, placeholder buffer and timer.
internal final class ExtensionDeviceRuntime: Sendable {
    internal struct StartResult: Sendable {
        /// A newly created placeholder timer the caller must resume, if any.
        let timer: DispatchSourceTimer?
    }

    internal struct StopResult: Sendable {
        let hasConsumers: Bool
        /// The placeholder timer the caller must cancel, if it was running.
        let timer: DispatchSourceTimer?
    }

    private struct State: Sendable {
        var sourceStream: SendableRetainedReference<CMIOExtensionStream>?
        var videoDescription: CMFormatDescription?
        var placeholderBuffer: SendableRetainedReference<CVPixelBuffer>?
        var streaming = ExtensionStreamingState()
        var timer: DispatchSourceTimer?
    }

    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    func configure(
        sourceStream: CMIOExtensionStream,
        videoDescription: CMFormatDescription,
        placeholderBuffer: CVPixelBuffer?
    ) {
        let retainedStream = SendableRetainedReference(sourceStream)
        let retainedBuffer = placeholderBuffer.map(SendableRetainedReference.init)
        state.withLock {
            $0.sourceStream = retainedStream
            $0.videoDescription = videoDescription
            $0.placeholderBuffer = retainedBuffer
        }
    }

    /// Count a new source-stream consumer. Always counts it, so live sink frames
    /// are forwarded even when the placeholder failed to render; only the
    /// placeholder timer depends on having a placeholder.
    func startStreaming(timerQueue: DispatchQueue) -> StartResult {
        state.withLock { state in
            guard state.streaming.consumerStarted(hasPlaceholder: state.placeholderBuffer != nil) else {
                return StartResult(timer: nil)
            }

            let timer = DispatchSource.makeTimerSource(flags: .strict, queue: timerQueue)
            timer.schedule(
                deadline: .now(),
                repeating: 1.0 / Tuning.placeholderFPS,
                leeway: .milliseconds(Tuning.placeholderTimerLeewayMs)
            )
            timer.setEventHandler { [weak self] in
                self?.emitPlaceholderFrame()
            }
            state.timer = timer
            return StartResult(timer: timer)
        }
    }

    func stopStreaming() -> StopResult {
        state.withLock { state in
            let outcome = state.streaming.consumerStopped()
            guard outcome.cancelPlaceholderTimer else {
                return StopResult(hasConsumers: outcome.hasConsumers, timer: nil)
            }
            let timer = state.timer
            state.timer = nil
            return StopResult(hasConsumers: outcome.hasConsumers, timer: timer)
        }
    }

    func startSinking() {
        state.withLock {
            $0.streaming.startSinking()
        }
    }

    func stopSinking() -> Bool {
        state.withLock { $0.streaming.stopSinking() }
    }

    func forwardSinkFrame(_ buffer: CMSampleBuffer) {
        let sourceStream = state.withLock { state -> SendableRetainedReference<CMIOExtensionStream>? in
            guard state.streaming.forwardsSinkFrames else { return nil }
            return state.sourceStream
        }
        guard let sourceStream else { return }

        let nanoSec = HostTimeNanoseconds.now()
        sourceStream.withValue {
            $0.send(buffer, discontinuity: [], hostTimeInNanoseconds: nanoSec)
        }
    }

    func emitPlaceholderFrame() {
        let frameState = state.withLock {
            (
                emitsPlaceholder: $0.streaming.emitsPlaceholder,
                sourceStream: $0.sourceStream,
                videoDescription: $0.videoDescription,
                placeholderBuffer: $0.placeholderBuffer
            )
        }

        guard frameState.emitsPlaceholder,
              let sourceStream = frameState.sourceStream,
              let videoDescription = frameState.videoDescription,
              let placeholderBuffer = frameState.placeholderBuffer else {
            return
        }

        var timingInfo = CMSampleTimingInfo()
        timingInfo.presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock())
        let sampleBuffer = placeholderBuffer.withValue { buffer -> CMSampleBuffer? in
            var sampleBuffer: CMSampleBuffer?
            let err = CMSampleBufferCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: buffer,
                dataReady: true,
                makeDataReadyCallback: nil,
                refcon: nil,
                formatDescription: videoDescription,
                sampleTiming: &timingInfo,
                sampleBufferOut: &sampleBuffer
            )
            guard err == noErr else { return nil }
            return sampleBuffer
        }

        guard let sampleBuffer else { return }
        sourceStream.withValue {
            $0.send(
                sampleBuffer,
                discontinuity: [],
                hostTimeInNanoseconds: HostTimeNanoseconds.nanosecondsOrNow(timingInfo.presentationTimeStamp)
            )
        }
    }
}

import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation
import os

internal final class ExtensionDeviceRuntime: Sendable {
    internal struct StartResult: Sendable {
        let didStart: Bool
        let timer: DispatchSourceTimer?
    }

    internal struct StopResult: Sendable {
        let hasConsumers: Bool
        let timer: DispatchSourceTimer?
    }

    private struct State: Sendable {
        var sourceStream: SendableRetainedReference<CMIOExtensionStream>?
        var videoDescription: CMFormatDescription?
        var placeholderBuffer: SendableRetainedReference<CVPixelBuffer>?
        var sinking = false
        var streamingCounter: UInt32 = 0
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

    func startStreaming(timerQueue: DispatchQueue) -> StartResult {
        state.withLock { state in
            guard state.placeholderBuffer != nil else {
                return StartResult(didStart: false, timer: nil)
            }

            state.streamingCounter += 1
            guard state.timer == nil else {
                return StartResult(didStart: true, timer: nil)
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
            return StartResult(didStart: true, timer: timer)
        }
    }

    func stopStreaming() -> StopResult {
        state.withLock { state in
            if state.streamingCounter > 1 {
                state.streamingCounter -= 1
                return StopResult(hasConsumers: true, timer: nil)
            }

            state.streamingCounter = 0
            let timer = state.timer
            state.timer = nil
            return StopResult(hasConsumers: false, timer: timer)
        }
    }

    func startSinking() {
        state.withLock {
            $0.sinking = true
        }
    }

    func stopSinking() -> Bool {
        state.withLock { state in
            guard state.sinking else { return false }
            state.sinking = false
            return true
        }
    }

    func forwardSinkFrame(_ buffer: CMSampleBuffer) {
        let sourceStream = state.withLock { state -> SendableRetainedReference<CMIOExtensionStream>? in
            guard state.streamingCounter > 0 else { return nil }
            return state.sourceStream
        }
        guard let sourceStream else { return }

        let pts = CMClockGetTime(CMClockGetHostTimeClock())
        let nanoSec = UInt64(pts.seconds * Double(NSEC_PER_SEC))
        sourceStream.withValue {
            $0.send(buffer, discontinuity: [], hostTimeInNanoseconds: nanoSec)
        }
    }

    func emitPlaceholderFrame() {
        let frameState = state.withLock {
            (
                sinking: $0.sinking,
                sourceStream: $0.sourceStream,
                videoDescription: $0.videoDescription,
                placeholderBuffer: $0.placeholderBuffer
            )
        }

        guard !frameState.sinking,
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
                hostTimeInNanoseconds: UInt64(timingInfo.presentationTimeStamp.seconds * Double(NSEC_PER_SEC))
            )
        }
    }
}

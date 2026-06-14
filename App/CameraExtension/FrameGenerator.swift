import CoreMedia
import CoreVideo
import Foundation
import os

internal final class FrameGenerator: Sendable {
    private struct State: Sendable {
        var timer: DispatchSourceTimer?
        var pixelBuffer: SendablePixelBuffer?
        var formatDescription: CMVideoFormatDescription?
    }

    private let model: LemurCamModel
    private let timerQueue = DispatchQueue(label: "placeholderGenerator", qos: .userInteractive)

    private let width: Int
    private let height: Int

    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    init(model: LemurCamModel) {
        self.model = model
        let resolution = LemurCamConfig.storedResolution
        self.width = Int(resolution.width)
        self.height = Int(resolution.height)
    }

    func start(message: String = "No camera available in LemurCam") {
        stop()
        setupPlaceholder(message: message)
        startGenerating()
    }

    func stop() {
        let timer = state.withLock { state in
            let timer = state.timer
            state.timer = nil
            return timer
        }
        timer?.cancel()
    }

    deinit {
        stop()
    }

    private func setupPlaceholder(message: String) {
        let newBuffer = PlaceholderRenderer.render(text: message, width: width, height: height)

        var newDesc: CMVideoFormatDescription?
        if let buf = newBuffer {
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: buf,
                formatDescriptionOut: &newDesc)
        }

        let formatDescription = newDesc
        let sendableBuffer = newBuffer.map(SendablePixelBuffer.init)
        state.withLock {
            $0.pixelBuffer = sendableBuffer
            $0.formatDescription = formatDescription
        }
    }

    private func startGenerating() {
        let newTimer = DispatchSource.makeTimerSource(flags: .strict, queue: timerQueue)
        // Static image — low frame rate is fine
        newTimer.schedule(
            deadline: .now(), repeating: 1.0 / Tuning.placeholderFPS,
            leeway: .milliseconds(Tuning.placeholderTimerLeewayMs)
        )

        newTimer.setEventHandler { [weak self] in
            self?.generateFrame()
        }
        newTimer.resume()

        let oldTimer = state.withLock { state in
            let timer = state.timer
            state.timer = newTimer
            return timer
        }
        oldTimer?.cancel()
    }

    private func generateFrame() {
        guard model.isStreaming else { return }

        let frameState = state.withLock {
            (pixelBuffer: $0.pixelBuffer, formatDescription: $0.formatDescription)
        }
        guard let frame = frameState.pixelBuffer,
              let desc = frameState.formatDescription else {
            return
        }

        let sampleBuffer = frame.withValue { buf -> CMSampleBuffer? in
            var sampleBuffer: CMSampleBuffer?
            var timing = CMSampleTimingInfo()
            timing.presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock())

            CMSampleBufferCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: buf,
                dataReady: true,
                makeDataReadyCallback: nil,
                refcon: nil,
                formatDescription: desc,
                sampleTiming: &timing,
                sampleBufferOut: &sampleBuffer)
            return sampleBuffer
        }

        if let sampleBuffer {
            model.sendSampleBuffer(sampleBuffer)
        }
    }
}

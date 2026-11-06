import CoreMedia
import os

internal final class FrameGenerator: Sendable {
    private struct State: Sendable {
        var timer: DispatchSourceTimer?
        var pixelBuffer: SendablePixelBuffer?
        var formatDescription: CMVideoFormatDescription?
        var message: String?
    }

    /// The text's size at 1080p; it scales with the placeholder's height.
    private static let fontSize: CGFloat = 48

    private let model: LemurCamModel
    private let timerQueue = DispatchQueue(label: "placeholderGenerator", qos: .userInteractive)

    /// The size to draw at: the user's Resolution setting, read each time a
    /// placeholder starts. The extension scales whatever it gets to the size the
    /// app using the camera runs at, so this only saves that step when they match.
    /// Injected for testability.
    private let resolution: @Sendable () -> LemurCamConfig.Resolution

    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    init(
        model: LemurCamModel,
        resolution: @escaping @Sendable () -> LemurCamConfig.Resolution = { LemurCamConfig.storedResolution }
    ) {
        self.model = model
        self.resolution = resolution
    }

    func start(message: String = "No camera available in LemurCam") {
        stop()
        setupPlaceholder(message: message)
        startGenerating()
    }

    /// The text of the placeholder being generated, or nil while stopped.
    var placeholderMessage: String? {
        state.withLock { $0.timer == nil ? nil : $0.message }
    }

    /// The size of the placeholder being generated, or nil while stopped or when
    /// it couldn't be drawn.
    var placeholderDimensions: CMVideoDimensions? {
        state.withLock { state in
            guard state.timer != nil, let description = state.formatDescription else { return nil }
            return CMVideoFormatDescriptionGetDimensions(description)
        }
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
        let size = resolution()
        let height = Int(size.height)
        let newBuffer = PlaceholderRenderer.render(
            text: message,
            width: Int(size.width),
            height: height,
            fontSize: PlaceholderRenderer.fontSize(Self.fontSize, forHeight: height)
        )

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
            $0.message = message
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

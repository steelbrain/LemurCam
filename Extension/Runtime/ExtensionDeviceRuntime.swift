import CoreMedia
import CoreMediaIO
import CoreVideo
import os

/// Lock-protected runtime state for `ExtensionDeviceSource`. The counting and
/// sink/placeholder decisions live in the pure `ExtensionStreamingState`, the
/// format decisions in `SourceFormatState` and the pacing in `FramePacer` (all
/// Shared/, unit-tested); this type adds the CMIO stream, the placeholder, the
/// scaler and the timer. Decisions are made under the lock; CMIO calls, drawing
/// and scaling happen outside it.
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

    /// What `forwardSinkFrame` does with one frame, decided under the lock.
    private enum ForwardRoute {
        case drop
        /// Send the app's sample buffer as it is: it already has the active format's
        /// size and pixel format, or it can't be scaled.
        case passThrough(SendableRetainedReference<CMIOExtensionStream>)
        /// Scale it to `resolution` with `scaler`, or with a new scaler when nil.
        case scale(
            SendableRetainedReference<CMIOExtensionStream>,
            scaler: SinkFrameScaler?,
            resolution: LemurCamConfig.Resolution
        )
    }

    /// A change of the source stream's format, decided under the lock. The caller
    /// announces `applied` and lets go of `retired` (the old format's scaler and its
    /// pool) after the lock is released.
    private struct FormatUpdate: Sendable {
        var applied: StreamFormatSelection?
        var retired: SinkFrameScaler?
    }

    /// What `emitPlaceholderFrame` needs, read under the lock.
    private struct PlaceholderSnapshot {
        let stream: SendableRetainedReference<CMIOExtensionStream>
        /// The active format's resolution, which the placeholder must have.
        let resolution: LemurCamConfig.Resolution
        let current: PlaceholderFrame
    }

    private struct State: Sendable {
        var sourceStream: SendableRetainedReference<CMIOExtensionStream>?
        var placeholder: PlaceholderFrame?
        var streaming = ExtensionStreamingState()
        var timer: DispatchSourceTimer?
        var format: SourceFormatState
        var pacer = FramePacer()
        /// The scaler for the active resolution, made by the first frame that
        /// needed it. Lent to one frame at a time (`scalerInUse`).
        var scaler: SinkFrameScaler?
        var scalerInUse = false
        /// A resolution no scaler could be made for; its frames go out unscaled
        /// rather than trying again on every frame.
        var unscalableResolution: LemurCamConfig.Resolution?

        /// The active format became `applied` (nil: it didn't change). The scaler
        /// and the pacing were for the old one.
        mutating func update(applying applied: StreamFormatSelection?) -> FormatUpdate {
            guard applied != nil else { return FormatUpdate() }
            let retired = scaler
            scaler = nil
            unscalableResolution = nil
            pacer.reset()
            return FormatUpdate(applied: applied, retired: retired)
        }

        mutating func route(
            width: Int, height: Int, pixelFormat: OSType, now: UInt64
        ) -> ForwardRoute {
            guard streaming.forwardsSinkFrames, let stream = sourceStream else { return .drop }
            let target = format.active
            let passesThrough = target.resolution == unscalableResolution || StreamFormatTable.passesThrough(
                width: width, height: height, pixelFormat: pixelFormat, to: target.resolution
            )
            // Another frame is being scaled; this one would have to wait for it.
            if !passesThrough, scalerInUse { return .drop }
            guard pacer.admit(atNanoseconds: now, frameDurationNanoseconds: target.frameDurationNanoseconds) else {
                return .drop
            }
            if passesThrough { return .passThrough(stream) }
            scalerInUse = true
            let current = scaler?.resolution == target.resolution ? scaler : nil
            return .scale(stream, scaler: current, resolution: target.resolution)
        }

        /// A frame is done with `used`, made for `resolution` (nil when none could be).
        mutating func finishScaling(with used: SinkFrameScaler?, for resolution: LemurCamConfig.Resolution) {
            scalerInUse = false
            // The format may have changed while the frame was scaled.
            guard resolution == format.active.resolution else { return }
            if let used {
                scaler = used
            } else {
                unscalableResolution = resolution
            }
        }
    }

    private let state: OSAllocatedUnfairLock<State>

    /// Announces format changes to the source stream's clients. Off the CMIO
    /// callback that caused them, so the announcement never re-enters CMIO from
    /// inside its own call.
    private let announceQueue = DispatchQueue(label: "cam.lemur.app.extension.formatAnnounce", qos: .userInitiated)

    init(initialFormat: StreamFormatSelection) {
        state = OSAllocatedUnfairLock(initialState: State(format: SourceFormatState(initial: initialFormat)))
    }

    func configure(sourceStream: CMIOExtensionStream, placeholder: PlaceholderFrame?) {
        let retainedStream = SendableRetainedReference(sourceStream)
        state.withLock {
            $0.sourceStream = retainedStream
            $0.placeholder = placeholder
        }
    }

    /// Count a new source-stream consumer. Always counts it, so live sink frames
    /// are forwarded even when the placeholder failed to render; only the
    /// placeholder timer depends on having a placeholder.
    func startStreaming(timerQueue: DispatchQueue) -> StartResult {
        state.withLock { state in
            guard state.streaming.consumerStarted(hasPlaceholder: state.placeholder != nil) else {
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

    /// Uncount a source-stream consumer. When the last one stops, a default format
    /// the app set while the camera was in use applies now.
    func stopStreaming() -> StopResult {
        let (result, update) = state.withLock { state -> (StopResult, FormatUpdate) in
            let outcome = state.streaming.consumerStopped()
            let idleUpdate = state.update(applying: outcome.hasConsumers ? nil : state.format.sourceBecameIdle())
            guard outcome.cancelPlaceholderTimer else {
                return (StopResult(hasConsumers: outcome.hasConsumers, timer: nil), idleUpdate)
            }
            let timer = state.timer
            state.timer = nil
            return (StopResult(hasConsumers: outcome.hasConsumers, timer: timer), idleUpdate)
        }
        if let applied = update.applied {
            announce(applied, reason: "the default, now that no app is using the camera")
        }
        return result
    }

    func startSinking() {
        state.withLock {
            $0.streaming.startSinking()
        }
    }

    func stopSinking() -> Bool {
        state.withLock { $0.streaming.stopSinking() }
    }
}

// MARK: - Formats

extension ExtensionDeviceRuntime {
    /// The source stream's format: what consuming apps get.
    var activeFormat: StreamFormatSelection {
        state.withLock { $0.format.active }
    }

    /// The default the app set on the sink stream.
    var preferredFormat: StreamFormatSelection {
        state.withLock { $0.format.preferred }
    }

    /// A consuming app set the source stream's format or frame rate.
    func setSourceFormat(_ request: ExtensionStreamFormats.Request) {
        let update = state.withLock { state -> FormatUpdate in
            let changed = state.format.sourceClientSet(resolution: request.resolution, frameRate: request.frameRate)
            return state.update(applying: changed ? state.format.active : nil)
        }
        if let applied = update.applied {
            announce(applied, reason: "an app's choice")
        }
    }

    /// The app set the default format or frame rate on the sink stream. It applies
    /// now if no app is using the camera, otherwise when the last one stops.
    func setDefaultFormat(_ request: ExtensionStreamFormats.Request) {
        let (update, waits) = state.withLock { state -> (FormatUpdate, Bool) in
            let hasConsumers = state.streaming.consumerCount > 0
            let applied = state.format.defaultSet(
                resolution: request.resolution, frameRate: request.frameRate, sourceHasConsumers: hasConsumers
            )
            return (state.update(applying: applied), hasConsumers)
        }
        if let applied = update.applied {
            announce(applied, reason: "the default")
        } else if waits {
            Log.ext.info("Default camera format set while the camera is in use; it applies when no app is using it")
        }
    }

    /// Log the source stream's new format and tell its clients, which otherwise
    /// keep the format they last read.
    private func announce(_ format: StreamFormatSelection, reason: String) {
        Log.ext.info("Camera format is \(format.resolution.rawValue) at \(format.frameRate.rawValue) fps: \(reason)")
        guard let stream = state.withLock({ $0.sourceStream }) else { return }
        announceQueue.async {
            let changes = ExtensionStreamFormats.properties(of: format).propertiesDictionary
            stream.withValue { $0.notifyPropertiesChanged(changes) }
        }
    }
}

// MARK: - Frames

extension ExtensionDeviceRuntime {
    /// Send a frame from the app to the source stream's consumers, paced to the
    /// active frame rate and scaled to the active resolution. A frame that already
    /// matches goes out as it is, without a copy.
    func forwardSinkFrame(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let now = HostTimeNanoseconds.now()

        switch state.withLock({ $0.route(width: width, height: height, pixelFormat: pixelFormat, now: now) }) {
        case .drop:
            return
        case .passThrough(let stream):
            stream.withValue { $0.send(sampleBuffer, discontinuity: [], hostTimeInNanoseconds: now) }
        case let .scale(stream, lent, resolution):
            // A new format's first frame makes its scaler, here rather than under the lock.
            let scaler = lent ?? SinkFrameScaler(resolution: resolution)
            let scaled = scaler?.scale(pixelBuffer, presentationTime: sampleBuffer.presentationTimeStamp)
            state.withLock { $0.finishScaling(with: scaler, for: resolution) }
            // A frame that couldn't be scaled still goes out, at its own size.
            let output = scaled ?? sampleBuffer
            stream.withValue { $0.send(output, discontinuity: [], hostTimeInNanoseconds: now) }
        }
    }

    /// Send the placeholder, at the active format's size, while the app sends no
    /// frames. Draws it again after a format change, on the timer queue.
    func emitPlaceholderFrame() {
        let snapshot = state.withLock { state -> PlaceholderSnapshot? in
            guard state.streaming.emitsPlaceholder,
                  let stream = state.sourceStream,
                  let placeholder = state.placeholder else { return nil }
            return PlaceholderSnapshot(stream: stream, resolution: state.format.active.resolution, current: placeholder)
        }
        guard let snapshot else { return }
        let resolution = snapshot.resolution
        let current = snapshot.current

        // `snapshot` still holds the placeholder being replaced, so it is freed
        // after the lock below, not under it.
        let placeholder: PlaceholderFrame
        if current.resolution == resolution {
            placeholder = current
        } else if let drawn = PlaceholderFrame.render(at: resolution) {
            placeholder = drawn
            state.withLock { $0.placeholder = drawn }
        } else {
            Log.ext.error("Couldn't draw the placeholder at \(resolution.rawValue); sending the last one")
            let kept = current.standingIn(for: resolution)
            placeholder = kept
            state.withLock { $0.placeholder = kept }
        }

        let presentationTime = CMClockGetTime(CMClockGetHostTimeClock())
        guard let sampleBuffer = placeholder.sampleBuffer(at: presentationTime) else { return }
        snapshot.stream.withValue {
            $0.send(
                sampleBuffer,
                discontinuity: [],
                hostTimeInNanoseconds: HostTimeNanoseconds.nanosecondsOrNow(presentationTime)
            )
        }
    }
}

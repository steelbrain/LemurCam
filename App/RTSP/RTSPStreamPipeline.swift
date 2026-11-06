import CoreVideo
import Foundation
import IPCamKit
import os

/// The pipeline surface `StreamCoordinator` drives. `RTSPStreamPipeline` is the
/// production conformer; tests substitute a recording fake to exercise retry and
/// demand handling without a camera.
internal protocol StreamPipeline: AnyObject, Sendable {
    var onPixelBuffer: (@Sendable (CVPixelBuffer) -> Void)? { get set }
    var onStateChanged: (@Sendable (RTSPStreamPipeline.State) -> Void)? { get set }
    var onStreamInfo: (@Sendable (RTSPStreamPipeline.StreamInfo) -> Void)? { get set }
    var onAudioPCM: (@Sendable (UnsafePointer<Float>, Int) -> Void)? { get set }

    func connect(url: String, credentials: SourceCredentials?)
    func disconnect()
    func cancelSilently()
}

internal final class RTSPStreamPipeline: StreamPipeline {
    enum State: Equatable, Sendable {
        case idle
        case connecting
        case streaming
        case disconnected
        case error(String)
    }

    struct TimeoutError: LocalizedError {
        var errorDescription: String? {
            "Connection timed out after \(Tuning.connectionTimeoutNs / 1_000_000_000) seconds"
        }
    }

    struct StreamStallError: LocalizedError {
        var errorDescription: String? {
            "Stream stalled — no data received for \(Tuning.streamStallTimeoutNs / 1_000_000_000) seconds"
        }
    }

    struct VideoDecodeStallError: LocalizedError {
        var errorDescription: String? {
            "Video stalled — no frame decoded for \(Tuning.videoDecodeStallTimeoutNs / 1_000_000_000) seconds"
        }
    }

    struct NoVideoStreamError: LocalizedError {
        var errorDescription: String? {
            "Camera session has no supported video stream"
        }
    }

    struct StreamInfo: Sendable {
        let width: Int?
        let height: Int?
        let codec: String
    }

    var onPixelBuffer: (@Sendable (CVPixelBuffer) -> Void)? {
        get { callbacks.withLock { $0.onPixelBuffer } }
        set { callbacks.withLock { $0.onPixelBuffer = newValue } }
    }

    var onStateChanged: (@Sendable (State) -> Void)? {
        get { callbacks.withLock { $0.onStateChanged } }
        set { callbacks.withLock { $0.onStateChanged = newValue } }
    }

    var onStreamInfo: (@Sendable (StreamInfo) -> Void)? {
        get { callbacks.withLock { $0.onStreamInfo } }
        set { callbacks.withLock { $0.onStreamInfo = newValue } }
    }

    /// Decoded camera audio as 48 kHz Float32 interleaved stereo PCM, ready for the
    /// virtual-microphone ring. Called from the frame-consuming task (not the main
    /// actor); the pointer is valid only for the duration of the call.
    var onAudioPCM: (@Sendable (UnsafePointer<Float>, Int) -> Void)? {
        get { callbacks.withLock { $0.onAudioPCM } }
        set { callbacks.withLock { $0.onAudioPCM = newValue } }
    }

    private struct Callbacks: Sendable {
        var onPixelBuffer: (@Sendable (CVPixelBuffer) -> Void)?
        var onStateChanged: (@Sendable (State) -> Void)?
        var onStreamInfo: (@Sendable (StreamInfo) -> Void)?
        var onAudioPCM: (@Sendable (UnsafePointer<Float>, Int) -> Void)?
    }

    private let callbacks = OSAllocatedUnfairLock<Callbacks>(initialState: Callbacks())
    private let pipelineState = OSAllocatedUnfairLock<State>(initialState: .idle)
    private let streamTask = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

    var state: State {
        pipelineState.withLock { $0 }
    }

    func connect(url: String, credentials: SourceCredentials?) {
        // Cancel previous task without firing state callbacks
        cancelStreamTask()

        setState(.connecting)

        let rtspCredentials: Credentials? = credentials.map {
            Credentials(username: $0.username, password: $0.password)
        }

        let task = Task { [weak self] in
            guard let self else { return }
            await self.runStream(url: url, credentials: rtspCredentials)
        }
        streamTask.withLock {
            $0 = task
        }
    }

    /// Disconnect and transition to .disconnected state (fires onStateChanged).
    func disconnect() {
        cancelStreamTask()
        if state != .idle {
            setState(.disconnected)
        }
    }

    /// Cancel any active stream without firing state callbacks.
    /// Used during deliberate source switches to avoid spurious retry scheduling.
    func cancelSilently() {
        cancelStreamTask()
    }

    // MARK: - Private

    private func runStream(url: String, credentials: Credentials?) async {
        let session = RTSPClientSession(url: url, credentials: credentials)

        do {
            let description = try await connectWithTimeout(session: session)
            guard !Task.isCancelled else {
                await session.stop()
                return
            }

            guard let video = description.video else {
                throw NoVideoStreamError()
            }

            let watchdog = StreamWatchdog()
            let processor = makeProcessor(for: video)
            let decoder = makeVideoDecoder(watchdog: watchdog)
            defer { decoder.tearDown() }
            let audioDecoder = description.audio.map(makeAudioDecoder)
            defer { audioDecoder?.tearDown() }

            setState(.streaming)
            Log.rtsp.info("Stream connected: \(video.codec)")
            publishStreamInfo(video)

            try await consumeFrames(
                session: session, watchdog: watchdog, processor: processor,
                decoder: decoder, audioDecoder: audioDecoder
            )

            await session.stop()

            if !Task.isCancelled {
                setState(.disconnected)
                Log.rtsp.info("Stream ended normally")
            }
        } catch {
            if !Task.isCancelled {
                setState(.error(error.localizedDescription))
                Log.rtsp.error("Stream error: \(error)")
            }
            await session.stop()
        }
    }

    private func makeProcessor(for video: VideoStream) -> NALProcessor {
        NALProcessor(
            codec: video.codec,
            sps: video.sps ?? Data(),
            pps: video.pps ?? Data(),
            vps: video.vps
        )
    }

    private func makeVideoDecoder(watchdog: StreamWatchdog) -> VideoDecoder {
        let decoder = VideoDecoder()
        decoder.onDecodedFrame = { [weak self] pixelBuffer in
            watchdog.markFrameDecoded()
            self?.emitPixelBuffer(pixelBuffer)
        }
        return decoder
    }

    private func makeAudioDecoder(_ audio: AudioStream) -> AudioDecoder {
        Log.rtsp.info("Audio stream: \(String(describing: audio.codec)) @\(audio.sampleRate)Hz")
        let decoder = AudioDecoder(stream: audio)
        decoder.onPCM = { [weak self] samples, frames in self?.emitAudioPCM(samples, frames: frames) }
        return decoder
    }

    private func connectWithTimeout(
        session: RTSPClientSession
    ) async throws -> SessionDescription {
        try await Self.withConnectTimeout(
            nanoseconds: Tuning.connectionTimeoutNs,
            start: { try await session.start() },
            abort: { await session.stop() }
        )
    }

    private func publishStreamInfo(_ video: VideoStream) {
        let codecName: String
        switch video.codec {
        case .h264: codecName = "H.264"
        case .h265: codecName = "H.265"
        }
        let info = StreamInfo(
            width: video.resolution?.width,
            height: video.resolution?.height,
            codec: codecName
        )
        emitStreamInfo(info)
    }

    private func cancelStreamTask() {
        streamTask.withLock {
            $0?.cancel()
            $0 = nil
        }
    }

    private func setState(_ newValue: State) {
        pipelineState.withLock {
            $0 = newValue
        }
        callbacks.withLock { $0.onStateChanged }?(newValue)
    }

    private func emitPixelBuffer(_ pixelBuffer: CVPixelBuffer) {
        callbacks.withLock { $0.onPixelBuffer }?(pixelBuffer)
    }

    private func emitStreamInfo(_ info: StreamInfo) {
        callbacks.withLock { $0.onStreamInfo }?(info)
    }

    private func emitAudioPCM(_ samples: UnsafePointer<Float>, frames: Int) {
        callbacks.withLock { $0.onAudioPCM }?(samples, frames)
    }

}

private extension RTSPStreamPipeline {
    func consumeFrames(
        session: RTSPClientSession,
        watchdog: StreamWatchdog,
        processor: NALProcessor,
        decoder: VideoDecoder,
        audioDecoder: AudioDecoder?
    ) async throws {
        let stallTask = makeStallTask(session: session, watchdog: watchdog)
        defer { stallTask.cancel() }

        do {
            for try await item in session.frames() {
                if Task.isCancelled { break }
                consumeFrameItem(
                    item, watchdog: watchdog, processor: processor,
                    decoder: decoder, audioDecoder: audioDecoder
                )
            }
        } catch {
            if let stall = watchdog.stall { throw stall.error }
            throw error
        }
        if let stall = watchdog.stall { throw stall.error }
    }

    /// Stops the session when the watchdog sees a stall, which ends `frames()` so
    /// `consumeFrames` throws the stall's error into the normal retry path.
    func makeStallTask(
        session: RTSPClientSession, watchdog: StreamWatchdog
    ) -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: Tuning.streamStallTimeoutNs)
                } catch {
                    return
                }
                if let stall = watchdog.checkForStall() {
                    Log.rtsp.warning("Stream watchdog: \(stall.error.localizedDescription)")
                    await session.stop()
                    return
                }
            }
        }
    }

    func consumeFrameItem(
        _ item: PublicCodecItem,
        watchdog: StreamWatchdog,
        processor: NALProcessor,
        decoder: VideoDecoder,
        audioDecoder: AudioDecoder?
    ) {
        switch item {
        case .video(let frame):
            watchdog.markFrameReceived()
            guard let processed = processor.process(frame) else { return }
            decoder.updateFormatDescription(processed.formatDescription, isKeyframe: processed.isKeyframe)
            decoder.decode(
                blockBuffer: processed.blockBuffer,
                formatDescription: processed.formatDescription,
                isKeyframe: processed.isKeyframe
            )
        case .audio(let frame):
            audioDecoder?.decode(frame)
        default:
            return
        }
    }
}

// MARK: - Connect Timeout

extension RTSPStreamPipeline {
    /// Run `start`, failing with `TimeoutError` once `timeoutNs` passes. IPCamKit's
    /// `RTSPClientSession.start()` ignores task cancellation, so cancelling it would
    /// leave the task group waiting for it past the timeout. `abort` ends it instead:
    /// the session's `stop()` during `start()` closes the connection at once and makes
    /// `start()` throw. A cancelled caller aborts the same way. After a timeout the
    /// result is `TimeoutError`, whatever `start` returns or throws afterwards.
    static func withConnectTimeout<Value: Sendable>(
        nanoseconds timeoutNs: UInt64,
        start: @escaping @Sendable () async throws -> Value,
        abort: @escaping @Sendable () async -> Void
    ) async throws -> Value {
        let timedOut = OSAllocatedUnfairLock(initialState: false)
        let outcome: Result<Value, any Error>
        do {
            let value = try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: Value.self) { group -> Value in
                    group.addTask { try await start() }
                    group.addTask {
                        try await Task.sleep(nanoseconds: timeoutNs)
                        timedOut.withLock { $0 = true }
                        await abort()
                        throw TimeoutError()
                    }
                    guard let value = try await group.next() else { throw TimeoutError() }
                    group.cancelAll()
                    return value
                }
            } onCancel: {
                Task { await abort() }
            }
            outcome = .success(value)
        } catch {
            outcome = .failure(error)
        }
        if timedOut.withLock({ $0 }) { throw TimeoutError() }
        return try outcome.get()
    }
}

// MARK: - Stall Watchdog

/// Tracks a stream's progress for the stall check: when the last video frame arrived
/// and when the decoder last produced a picture. Frames are marked on the frame loop
/// and decodes on VideoToolbox's output thread, hence the lock. Times are uptime
/// nanoseconds, passed in by tests.
internal final class StreamWatchdog: Sendable {
    enum Stall: Equatable, Sendable {
        /// No video frame arrived within `Tuning.streamStallTimeoutNs`.
        case noData
        /// Video frames kept arriving, but none decoded within
        /// `Tuning.videoDecodeStallTimeoutNs`: the decoder or its format description
        /// failed, or the stream never delivers a keyframe. Packets alone would keep
        /// the status at "streaming" with the picture frozen.
        case noDecodedVideo

        var error: any Error {
            switch self {
            case .noData: return RTSPStreamPipeline.StreamStallError()
            case .noDecodedVideo: return RTSPStreamPipeline.VideoDecodeStallError()
            }
        }
    }

    private struct State: Sendable {
        var lastFrame: UInt64
        var lastDecoded: UInt64
        var stall: Stall?
    }

    private let state: OSAllocatedUnfairLock<State>

    /// Both clocks start now: a stream that never decodes a frame counts from here.
    init(now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        state = OSAllocatedUnfairLock(initialState: State(lastFrame: now, lastDecoded: now))
    }

    /// The stall the last `checkForStall` found, if any. Once found it stays.
    var stall: Stall? {
        state.withLock { $0.stall }
    }

    func markFrameReceived(now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        state.withLock { $0.lastFrame = max($0.lastFrame, now) }
    }

    func markFrameDecoded(now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        state.withLock { $0.lastDecoded = max($0.lastDecoded, now) }
    }

    /// Record and return a stall, or nil while the stream is progressing. A missing
    /// frame flow is reported first: without frames there is nothing to decode.
    func checkForStall(
        now: UInt64 = DispatchTime.now().uptimeNanoseconds,
        dataTimeout: UInt64 = Tuning.streamStallTimeoutNs,
        decodeTimeout: UInt64 = Tuning.videoDecodeStallTimeoutNs
    ) -> Stall? {
        state.withLock { state in
            guard state.stall == nil else { return state.stall }
            // A mark can land between reading `now` and taking the lock, so a
            // timestamp may be later than `now`; count that as no time passed.
            func elapsed(since time: UInt64) -> UInt64 { now > time ? now - time : 0 }
            if elapsed(since: state.lastFrame) >= dataTimeout {
                state.stall = .noData
            } else if elapsed(since: state.lastDecoded) >= decodeTimeout {
                state.stall = .noDecodedVideo
            }
            return state.stall
        }
    }
}

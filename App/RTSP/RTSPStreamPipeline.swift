import CoreVideo
import Foundation
import IPCamKit
import os

/// Names one `connect` call. State changes are reported with the connection they
/// belong to, so a change from a connection that has since been cancelled or
/// replaced can be told apart from one about the current connection.
internal struct StreamConnectionID: Hashable, Sendable {
    let rawValue: UInt64

    /// Before the first `connect`.
    static let initial = Self(rawValue: 0)

    func next() -> Self {
        Self(rawValue: rawValue &+ 1)
    }
}

/// The pipeline surface `StreamCoordinator` drives. `RTSPStreamPipeline` is the
/// production conformer; tests substitute a recording fake to exercise retry and
/// demand handling without a camera.
internal protocol StreamPipeline: AnyObject, Sendable {
    /// Called with each decoded frame and the connection it came from, on the
    /// decoder's output thread.
    var onPixelBuffer: (@Sendable (CVPixelBuffer, StreamConnectionID) -> Void)? { get set }
    /// Called with each state change and the connection it belongs to: the ID the
    /// `connect` call that started it returned.
    var onStateChanged: (@Sendable (RTSPStreamPipeline.State, StreamConnectionID) -> Void)? { get set }
    /// Called with a connected stream's video format and the connection it describes.
    var onStreamInfo: (@Sendable (RTSPStreamPipeline.StreamInfo, StreamConnectionID) -> Void)? { get set }
    var onAudioPCM: (@Sendable (UnsafePointer<Float>, Int) -> Void)? { get set }

    /// Starts a new connection, replacing any current one, and returns its ID.
    func connect(url: String, credentials: SourceCredentials?) -> StreamConnectionID
    func disconnect()
    func cancelSilently()
}

internal final class RTSPStreamPipeline: StreamPipeline {
    enum State: Equatable, Sendable {
        case idle
        case connecting
        case streaming
        case disconnected
        /// `hostUnreachable`: no connection to the camera's host could be made (see
        /// `failureState(for:afterSetup:)`), as opposed to a camera that answered.
        case error(String, hostUnreachable: Bool = false)
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
            let seconds = Tuning.videoDecodeStallTimeoutNs / 1_000_000_000
            return "Video stalled — a keyframe arrived but nothing decoded for \(seconds) seconds"
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

    var onPixelBuffer: (@Sendable (CVPixelBuffer, StreamConnectionID) -> Void)? {
        get { callbacks.withLock { $0.onPixelBuffer } }
        set { callbacks.withLock { $0.onPixelBuffer = newValue } }
    }

    var onStateChanged: (@Sendable (State, StreamConnectionID) -> Void)? {
        get { callbacks.withLock { $0.onStateChanged } }
        set { callbacks.withLock { $0.onStateChanged = newValue } }
    }

    var onStreamInfo: (@Sendable (StreamInfo, StreamConnectionID) -> Void)? {
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
        var onPixelBuffer: (@Sendable (CVPixelBuffer, StreamConnectionID) -> Void)?
        var onStateChanged: (@Sendable (State, StreamConnectionID) -> Void)?
        var onStreamInfo: (@Sendable (StreamInfo, StreamConnectionID) -> Void)?
        var onAudioPCM: (@Sendable (UnsafePointer<Float>, Int) -> Void)?
    }

    private let callbacks = OSAllocatedUnfairLock<Callbacks>(initialState: Callbacks())
    private let pipelineState = OSAllocatedUnfairLock<State>(initialState: .idle)
    private let streamTask = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
    private let latestConnection = OSAllocatedUnfairLock(initialState: StreamConnectionID.initial)

    var state: State {
        pipelineState.withLock { $0 }
    }

    func connect(url: String, credentials: SourceCredentials?) -> StreamConnectionID {
        // Cancel previous task without firing state callbacks
        cancelStreamTask()

        let connection = latestConnection.withLock { latest in
            latest = latest.next()
            return latest
        }
        setState(.connecting, connection: connection)

        let rtspCredentials: Credentials? = credentials.map {
            Credentials(username: $0.username, password: $0.password)
        }

        let task = Task { [weak self] in
            guard let self else { return }
            await self.runStream(url: url, credentials: rtspCredentials, connection: connection)
        }
        streamTask.withLock {
            $0 = task
        }
        return connection
    }

    /// Disconnect and transition to .disconnected state (fires onStateChanged).
    func disconnect() {
        cancelStreamTask()
        if state != .idle {
            setState(.disconnected, connection: latestConnection.withLock { $0 })
        }
    }

    /// Cancel any active stream without firing state callbacks.
    /// Used during deliberate source switches to avoid spurious retry scheduling.
    func cancelSilently() {
        cancelStreamTask()
    }

    // MARK: - Private

    private func runStream(url: String, credentials: Credentials?, connection: StreamConnectionID) async {
        let session = RTSPClientSession(url: url, credentials: credentials)
        var setUp = false

        do {
            let description = try await connectWithTimeout(session: session)
            setUp = true
            guard !Task.isCancelled else {
                await session.stop()
                return
            }

            guard let video = description.video else {
                throw NoVideoStreamError()
            }

            let watchdog = StreamWatchdog()
            let processor = makeProcessor(for: video)
            let decoder = makeVideoDecoder(watchdog: watchdog, connection: connection)
            defer { decoder.tearDown() }
            let audioDecoder = description.audio.map(makeAudioDecoder)
            defer { audioDecoder?.tearDown() }

            setState(.streaming, connection: connection)
            Log.rtsp.info("Stream connected: \(video.codec)")
            publishStreamInfo(video, connection: connection)

            try await consumeFrames(
                session: session, watchdog: watchdog, processor: processor,
                decoder: decoder, audioDecoder: audioDecoder
            )

            await session.stop()

            if !Task.isCancelled {
                setState(.disconnected, connection: connection)
                Log.rtsp.info("Stream ended normally")
            }
        } catch {
            // A connection cancelled while connecting (a source switch, demand gone)
            // ends with `start()` throwing `CancellationError`: no failure to show or
            // retry, as nothing reports a cancelled connection.
            if !Task.isCancelled {
                setState(Self.failureState(for: error, afterSetup: setUp), connection: connection)
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

    private func makeVideoDecoder(watchdog: StreamWatchdog, connection: StreamConnectionID) -> VideoDecoder {
        let decoder = VideoDecoder()
        decoder.onDecodedFrame = { [weak self] pixelBuffer in
            watchdog.markFrameDecoded()
            self?.emitPixelBuffer(pixelBuffer, connection: connection)
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
        try await Self.withConnectTimeout(nanoseconds: Tuning.connectionTimeoutNs) { try await session.start() }
    }

    private func publishStreamInfo(_ video: VideoStream, connection: StreamConnectionID) {
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
        emitStreamInfo(info, connection: connection)
    }

    private func cancelStreamTask() {
        streamTask.withLock {
            $0?.cancel()
            $0 = nil
        }
    }

    private func setState(_ newValue: State, connection: StreamConnectionID) {
        pipelineState.withLock {
            $0 = newValue
        }
        callbacks.withLock { $0.onStateChanged }?(newValue, connection)
    }

    private func emitPixelBuffer(_ pixelBuffer: CVPixelBuffer, connection: StreamConnectionID) {
        callbacks.withLock { $0.onPixelBuffer }?(pixelBuffer, connection)
    }

    private func emitStreamInfo(_ info: StreamInfo, connection: StreamConnectionID) {
        callbacks.withLock { $0.onStreamInfo }?(info, connection)
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
            watchdog.markFrameReceived(isKeyframe: frame.isKeyframe)
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
    /// Run `start`, failing with `TimeoutError` once `timeoutNs` passes. Whichever
    /// comes first, `start`'s result or the timeout, is the result, and the other is
    /// cancelled, as `start` is when the caller is cancelled. IPCamKit's
    /// `RTSPClientSession.start()` ends at once when cancelled: it closes the
    /// connection, as `stop()` does, and throws `CancellationError`. So the limit
    /// holds, and a source switch doesn't leave a connect to the old camera running.
    /// After a timeout the result is `TimeoutError`, whatever `start` returns or
    /// throws afterwards.
    static func withConnectTimeout<Value: Sendable>(
        nanoseconds timeoutNs: UInt64,
        start: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await start() }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNs)
                throw TimeoutError()
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else { throw TimeoutError() }
            return value
        }
    }
}

// MARK: - Stall Watchdog

/// Tracks a stream's progress for the stall check: when the last video frame arrived,
/// and since when a keyframe has been waiting for the decoder to produce a picture.
/// Frames are marked on the frame loop and decodes on VideoToolbox's output thread,
/// hence the lock. Times are uptime nanoseconds, passed in by tests.
internal final class StreamWatchdog: Sendable {
    enum Stall: Equatable, Sendable {
        /// No video frame arrived within `Tuning.streamStallTimeoutNs`.
        case noData
        /// A keyframe arrived, but no frame decoded within
        /// `Tuning.videoDecodeStallTimeoutNs` of it: the decoder session or the format
        /// description failed. Packets alone would keep the status at "streaming"
        /// with the picture frozen. Waiting for a keyframe (at stream start, or after
        /// packet loss) never counts: with long keyframe intervals that is normal.
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
        /// When the oldest keyframe still waiting for a decoded picture arrived; nil
        /// once the decoder produced a frame after it.
        var undecodedKeyframeSince: UInt64?
        var stall: Stall?
    }

    private let state: OSAllocatedUnfairLock<State>

    /// The data clock starts now: a stream that never sends a frame counts from here.
    init(now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        state = OSAllocatedUnfairLock(initialState: State(lastFrame: now))
    }

    /// The stall the last `checkForStall` found, if any. Once found it stays.
    var stall: Stall? {
        state.withLock { $0.stall }
    }

    /// A video frame arrived. A keyframe starts the decode clock unless an earlier
    /// keyframe is already waiting for a decoded picture.
    func markFrameReceived(isKeyframe: Bool = false, now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        state.withLock { state in
            state.lastFrame = max(state.lastFrame, now)
            if isKeyframe, state.undecodedKeyframeSince == nil {
                state.undecodedKeyframeSince = now
            }
        }
    }

    /// The decoder produced a picture, so it is working: stop the decode clock.
    func markFrameDecoded() {
        state.withLock { $0.undecodedKeyframeSince = nil }
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
            } else if let keyframeAt = state.undecodedKeyframeSince, elapsed(since: keyframeAt) >= decodeTimeout {
                state.stall = .noDecodedVideo
            }
            return state.stall
        }
    }
}

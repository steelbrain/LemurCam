import CoreVideo
import Foundation
import IPCamKit
import os

internal final class RTSPStreamPipeline: Sendable {
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

            let processor = makeProcessor(for: video)
            let decoder = makeVideoDecoder()
            defer { decoder.tearDown() }
            let audioDecoder = description.audio.map(makeAudioDecoder)
            defer { audioDecoder?.tearDown() }

            setState(.streaming)
            Log.rtsp.info("Stream connected: \(video.codec)")
            publishStreamInfo(video)

            try await consumeFrames(
                session: session, processor: processor,
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

    private func makeVideoDecoder() -> VideoDecoder {
        let decoder = VideoDecoder()
        decoder.onDecodedFrame = { [weak self] pixelBuffer in
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
        try await withThrowingTaskGroup(
            of: SessionDescription.self
        ) { group -> SessionDescription in
            group.addTask {
                try await session.start()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: Tuning.connectionTimeoutNs)
                throw TimeoutError()
            }
            guard let result = try await group.next() else {
                throw TimeoutError()
            }
            group.cancelAll()
            return result
        }
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
        processor: NALProcessor,
        decoder: VideoDecoder,
        audioDecoder: AudioDecoder?
    ) async throws {
        let watchdog = StreamWatchdog()
        let stallTask = makeStallTask(session: session, watchdog: watchdog)
        defer { stallTask.cancel() }

        do {
            for try await item in session.frames() {
                if Task.isCancelled { break }
                await consumeFrameItem(
                    item, watchdog: watchdog, processor: processor,
                    decoder: decoder, audioDecoder: audioDecoder
                )
            }
        } catch {
            if await watchdog.didStall { throw StreamStallError() }
            throw error
        }
        if await watchdog.didStall { throw StreamStallError() }
    }

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
                if await watchdog.isStalled(timeout: Tuning.streamStallTimeoutNs) {
                    await watchdog.markStalled()
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
    ) async {
        switch item {
        case .video(let frame):
            await watchdog.markFrameReceived()
            guard let processed = processor.process(frame) else { return }
            decoder.updateFormatDescription(processed.formatDescription)
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

private actor StreamWatchdog {
    private var lastFrameTime: UInt64 = DispatchTime.now().uptimeNanoseconds
    private var stalled = false

    func markFrameReceived() {
        lastFrameTime = DispatchTime.now().uptimeNanoseconds
    }

    func isStalled(timeout: UInt64) -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        return (now - lastFrameTime) >= timeout
    }

    func markStalled() {
        stalled = true
    }

    var didStall: Bool {
        stalled
    }
}

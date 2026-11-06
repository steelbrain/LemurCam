import CoreVideo
import Foundation
@testable import LemurCam
import os
import XCTest

/// H.264 parameter sets for a 64x64 Constrained Baseline stream, taken from an
/// x264 encode. Unlike the hand-written minimal SPS in `NALProcessorTests`,
/// CoreMedia accepts these, so they build a real format description.
internal enum H264TestStream {
    static let sps = Data([
        0x67, 0x42, 0xC0, 0x0A, 0xDC, 0x42, 0x6C, 0x04, 0x40, 0x00, 0x00,
        0x03, 0x00, 0x40, 0x00, 0x00, 0x03, 0x00, 0x83, 0xC4, 0x89, 0xE0
    ])
    static let pps = Data([0x68, 0xCE, 0x0F, 0x2C, 0x80])

    /// Bytes CoreMedia rejects as an SPS (a truncated header).
    static let invalidSPS = Data([0x67, 0xFF])

    /// An IDR slice NAL header (type 5) with a token payload.
    static func keyframe(loss: UInt16 = 0) -> VideoFrameInput {
        VideoFrameInput(nalus: [Data([0x65, 0x88, 0x84])], isKeyframe: true, loss: loss)
    }

    /// A non-IDR slice NAL header (type 1) with a token payload.
    static func deltaFrame(loss: UInt16 = 0) -> VideoFrameInput {
        VideoFrameInput(nalus: [Data([0x41, 0x9A, 0x02])], isKeyframe: false, loss: loss)
    }
}

/// A `StreamPipeline` that records what `StreamCoordinator` asks of it and lets a
/// test drive the state callbacks the real pipeline would fire. Like the real one,
/// `connect` reports `.connecting` straight away, and numbers its connections.
internal final class FakeStreamPipeline: StreamPipeline {
    private struct State {
        var onPixelBuffer: (@Sendable (CVPixelBuffer) -> Void)?
        var onStateChanged: (@Sendable (RTSPStreamPipeline.State, StreamConnectionID) -> Void)?
        var onStreamInfo: (@Sendable (RTSPStreamPipeline.StreamInfo) -> Void)?
        var onAudioPCM: (@Sendable (UnsafePointer<Float>, Int) -> Void)?
        var connectedURLs: [String] = []
        var connectedCredentials: [SourceCredentials?] = []
        var latestConnection = StreamConnectionID.initial
        var silentCancels = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var onPixelBuffer: (@Sendable (CVPixelBuffer) -> Void)? {
        get { state.withLock { $0.onPixelBuffer } }
        set { state.withLock { $0.onPixelBuffer = newValue } }
    }

    var onStateChanged: (@Sendable (RTSPStreamPipeline.State, StreamConnectionID) -> Void)? {
        get { state.withLock { $0.onStateChanged } }
        set { state.withLock { $0.onStateChanged = newValue } }
    }

    var onStreamInfo: (@Sendable (RTSPStreamPipeline.StreamInfo) -> Void)? {
        get { state.withLock { $0.onStreamInfo } }
        set { state.withLock { $0.onStreamInfo = newValue } }
    }

    var onAudioPCM: (@Sendable (UnsafePointer<Float>, Int) -> Void)? {
        get { state.withLock { $0.onAudioPCM } }
        set { state.withLock { $0.onAudioPCM = newValue } }
    }

    /// Every URL passed to `connect`, in order.
    var connectedURLs: [String] {
        state.withLock { $0.connectedURLs }
    }

    /// The credentials passed with each URL in `connectedURLs`.
    var connectedCredentials: [SourceCredentials?] {
        state.withLock { $0.connectedCredentials }
    }

    var silentCancels: Int {
        state.withLock { $0.silentCancels }
    }

    /// The ID the last `connect` returned.
    var latestConnection: StreamConnectionID {
        state.withLock { $0.latestConnection }
    }

    func connect(url: String, credentials: SourceCredentials?) -> StreamConnectionID {
        let connection = state.withLock { state in
            state.connectedURLs.append(url)
            state.connectedCredentials.append(credentials)
            state.latestConnection = state.latestConnection.next()
            return state.latestConnection
        }
        emit(.connecting, connection: connection)
        return connection
    }

    func disconnect() {}

    func cancelSilently() {
        state.withLock { $0.silentCancels += 1 }
    }

    /// Fire `onStateChanged` as the real pipeline would from the stream task of
    /// its latest connection.
    func emit(_ newState: RTSPStreamPipeline.State) {
        emit(newState, connection: latestConnection)
    }

    /// Fire `onStateChanged` for `connection`, which may be an earlier one.
    func emit(_ newState: RTSPStreamPipeline.State, connection: StreamConnectionID) {
        onStateChanged?(newState, connection)
    }
}

/// Polls `condition` on the main actor until it holds or `timeout` passes, and
/// returns whether it held. Lets the coordinator's main-actor tasks run in between.
@MainActor
internal func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() >= deadline { return false }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return true
}

/// Captures `DualLogger` lines through its process-wide `onEmit` sink. Install it in
/// `setUp` and call `uninstall()` in `tearDown`, which restores the previous sink so
/// a running host app keeps its log view.
internal final class LogLineRecorder: Sendable {
    private let lines = OSAllocatedUnfairLock<[String]>(initialState: [])
    private let previous = OSAllocatedUnfairLock<(@Sendable (String, String, String) -> Void)?>(
        initialState: nil
    )

    func install() {
        let saved = DualLogger.onEmit
        previous.withLock { $0 = saved }
        DualLogger.onEmit = { [lines] _, _, message in
            lines.withLock { $0.append(message) }
        }
    }

    func uninstall() {
        DualLogger.onEmit = previous.withLock { $0 }
    }

    /// The number of captured lines that start with `prefix`.
    func count(startingWith prefix: String) -> Int {
        lines.withLock { $0.filter { $0.hasPrefix(prefix) }.count }
    }
}

/// A `StreamCoordinator` wired to a `FakeStreamPipeline` and a `SourceManager` with
/// throwaway storage and an in-memory credential store in place of the Keychain.
/// `SourceManager` persists the active source in the host app's
/// standard defaults, so `cleanUp()` restores that value. Its `LemurCamModel`
/// finds no consumer at discovery and never reads a real CMIO device, and its audio
/// ring is a private shm region, never the one a live driver maps, so tests may
/// call `start()`. The launch probes default to "no consumer". `rtspSources` are
/// added before the coordinator exists, as the app loads saved cameras before
/// creating it. No HAL listener is installed: `start()` hands the harness the
/// device-list callback, which `simulateAudioDeviceListChange()` fires.
@MainActor
internal final class CoordinatorHarness {
    let manager: SourceManager
    let pipeline: FakeStreamPipeline
    let coordinator: StreamCoordinator
    private let directory: URL
    private let savedActiveID: String?
    private let ringName = "/lc-test-\(UUID().uuidString.prefix(8))"
    private let audioDeviceListChange = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)

    /// `onvifEnvironment` stands in for the network when an ONVIF camera's stream
    /// URI is resolved; the default is the real one.
    init(
        rtspSources: [String] = [],
        cameraConsumerProbe: @escaping () -> Bool = { false },
        audioConsumerProbe: @escaping @Sendable () -> Bool = { false },
        onvifEnvironment: ONVIFResolveEnvironment = .live
    ) {
        savedActiveID = UserDefaults.standard.string(forKey: LemurCamConfig.activeSourceKey)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storage = SourceStorage(fileURL: directory.appendingPathComponent("sources.json"))
        let sourceManager = SourceManager(storage: storage, keychain: InMemoryCredentialStore())
        for name in rtspSources {
            try? sourceManager.addSource(name: name, sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://\(name)")))
        }
        let fakePipeline = FakeStreamPipeline()
        manager = sourceManager
        pipeline = fakePipeline
        coordinator = StreamCoordinator(
            sourceManager: sourceManager,
            audioConsumerProbe: audioConsumerProbe,
            cameraConsumerProbe: cameraConsumerProbe,
            audioDeviceListObserver: { [audioDeviceListChange] _, onChange in
                audioDeviceListChange.withLock { $0 = onChange }
                return nil
            },
            audioRing: AudioRingBuffer(name: ringName),
            model: LemurCamModel(consumerProbe: { _ in false }),
            pipeline: fakePipeline,
            onvifEnvironment: onvifEnvironment
        )
    }

    func cleanUp() {
        if let savedActiveID {
            UserDefaults.standard.set(savedActiveID, forKey: LemurCamConfig.activeSourceKey)
        } else {
            UserDefaults.standard.removeObject(forKey: LemurCamConfig.activeSourceKey)
        }
        try? FileManager.default.removeItem(at: directory)
        // Exists only if the test called `start()`; the mapping goes with the ring.
        shm_unlink(ringName)
    }

    /// Add an RTSP source at `rtsp://<name>` and return its ID.
    func addRTSP(_ name: String) -> UUID? {
        try? manager.addSource(name: name, sourceType: .rtsp(RTSPSourceInfo(url: "rtsp://\(name)")))
        return manager.sources.last?.id
    }

    func status(_ id: UUID) -> ConnectionStatus? {
        manager.connectionStatuses[id]
    }

    /// Whether `start()` has installed the HAL device-list listener.
    var isObservingAudioDevices: Bool {
        audioDeviceListChange.withLock { $0 != nil }
    }

    /// Fire the HAL device-list change, as CoreAudio does on the coordinator's queue.
    func simulateAudioDeviceListChange() {
        audioDeviceListChange.withLock { $0 }?()
    }

    /// Send `count` decoded frames to the coordinator, as the real pipeline does
    /// from VideoToolbox's output thread.
    func deliverDecodedFrames(_ count: Int) throws {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer)
        XCTAssertEqual(status, kCVReturnSuccess)
        let frame = try XCTUnwrap(buffer)
        for _ in 0..<count {
            pipeline.onPixelBuffer?(frame)
        }
    }
}

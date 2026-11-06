import Foundation

@MainActor
internal final class StreamCoordinator {
    let model: LemurCamModel
    let previewStore: PreviewStore

    private let sourceManager: SourceManager
    private let pipeline: any StreamPipeline
    private let fallbackGenerator: FrameGenerator
    private let frameDispatcher: StreamFrameDispatcher
    private var currentSourceID: UUID?
    private var currentSourceUpdatedAt: Date?
    /// The pipeline connection this coordinator runs, as `connect` named it; nil
    /// once it cancelled that connection and has not started another.
    private var currentConnection: StreamConnectionID?
    private var retryTask: Task<Void, Never>?
    private var onvifTask: Task<Void, Never>?
    private var backoff = ReconnectBackoff()
    private let firstDecodedFrame = FirstDecodedFrameSignal()
    private var _hasConsumers: Bool = false
    private let micDemand: VirtualMicDemand
    private let audioRing: AudioRingBuffer
    /// Whether an external app is already using the virtual camera; injected for testability.
    private let cameraConsumerProbe: () -> Bool
    /// The ONVIF stream-URI resolve's network operations; injected for testability.
    private let onvifEnvironment: ONVIFResolveEnvironment
    /// The aggregate-demand value we last acted on. Demand changes that don't cross
    /// the zero/non-zero boundary leave an already-running stream alone, so toggling
    /// one consumer never tears down and reconnects a stream another consumer needs.
    private var lastDemand = false

    var hasDemand: Bool {
        _hasConsumers || micDemand.hasConsumers || previewStore.isPreviewEnabled
    }

    /// Whether an external app is consuming the virtual camera, as tracked in this
    /// process from the extension's Darwin consumer notifications and what
    /// `LemurCamModel` learns from CMIO (device loss, discovery). Read-only.
    var hasExternalConsumers: Bool { _hasConsumers }

    /// `audioConsumerProbe` (whether the virtual mic runs IO) and
    /// `audioDeviceListObserver` are called off the main thread. `audioRing` and
    /// `model` are injectable so tests can use a private shm region and a consumer
    /// probe that never reads a real CMIO device.
    init(
        sourceManager: SourceManager,
        audioConsumerProbe: @escaping @Sendable () -> Bool = { VirtualMicProbe.isVirtualMicRunning() },
        cameraConsumerProbe: @escaping () -> Bool = { CoreMediaIOUtil.lemurCameraHasExternalConsumer() },
        audioDeviceListObserver: @escaping AudioDeviceListObserving = { queue, onChange in
            AudioDeviceListObserver(queue: queue, handler: onChange)
        },
        audioRing: AudioRingBuffer = AudioRingBuffer(),
        model streamModel: LemurCamModel = LemurCamModel(),
        pipeline: any StreamPipeline = RTSPStreamPipeline(),
        onvifEnvironment: ONVIFResolveEnvironment = .live
    ) {
        let previews = PreviewStore()

        self.model = streamModel
        self.previewStore = previews
        self.sourceManager = sourceManager
        self.pipeline = pipeline
        self.onvifEnvironment = onvifEnvironment
        self.micDemand = VirtualMicDemand(probe: audioConsumerProbe, makeDeviceListObserver: audioDeviceListObserver)
        self.audioRing = audioRing
        self.cameraConsumerProbe = cameraConsumerProbe
        self.fallbackGenerator = FrameGenerator(model: streamModel)
        self.frameDispatcher = StreamFrameDispatcher(
            model: streamModel,
            updatePreviewFPS: { [weak previews] fps in
                previews?.estimatedFPS = fps
            },
            updatePreviewImage: { [weak previews] image in
                previews?.latestFrame = image
            }
        )

        wirePipelineCallbacks()
        wireSourceCallbacks()
        observeConsumerChanges()
    }

    func start() {
        frameDispatcher.setPreviewEnabled(previewStore.isPreviewEnabled)
        audioRing.open()
        _hasConsumers = cameraConsumerProbe()
        syncToActiveSource(force: true)
        // Record the demand state we just brought the pipeline into, so the first
        // consumer notification doesn't read as a spurious edge and reconnect.
        lastDemand = hasDemand
        micDemand.observeDeviceList()
        Task { [weak self] in await self?.recoverAudioDemandOnLaunch() }
    }

    /// Recover audio demand missed at launch: a `consumerStarted` Darwin notification
    /// that fired before observers registered is not replayed, so seed from the device's
    /// running state. Split from `start()` for testability. The device is read off the
    /// main thread and its answer lands like a consumer notification: a mic in use
    /// starts the stream, and an idle one explicitly ends production too, since the
    /// shared region can outlive an earlier app run that left it marked as producing.
    func recoverAudioDemandOnLaunch() async {
        await micDemand.refreshFromDevice()
    }

    /// Run CMIO device discovery for the virtual camera. Called by the
    /// `SetupCoordinator` once the extension is installed and the device is live.
    func beginCameraDiscovery() {
        model.beginDiscovery()
    }

    deinit {
        retryTask?.cancel()
        pipeline.disconnect()
        fallbackGenerator.stop()

        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterRemoveEveryObserver(
            center, Unmanaged.passUnretained(self).toOpaque()
        )
    }

    private func wirePipelineCallbacks() {
        let dispatcher = frameDispatcher
        let firstFrame = firstDecodedFrame
        let resetBackoff: @MainActor @Sendable () -> Void = { [weak self] in self?.backoff.reset() }
        pipeline.onPixelBuffer = { pixelBuffer in
            dispatcher.handleDecodedFrame(pixelBuffer)
            if firstFrame.take() {
                Task { @MainActor in resetBackoff() }
            }
        }

        let ringBuffer = audioRing
        pipeline.onAudioPCM = { samples, frames in
            ringBuffer.write(samples, frames: frames)
        }

        let handleStateChange: @MainActor @Sendable (
            RTSPStreamPipeline.State, StreamConnectionID
        ) -> Void = { [weak self] state, connection in
            self?.handlePipelineStateChanged(state, connection: connection)
        }
        // Always hops, even when `connect` reports `.connecting` on the main thread:
        // the change must land after `connect` returned the ID it is checked against.
        pipeline.onStateChanged = { state, connection in
            Task { @MainActor in handleStateChange(state, connection) }
        }

        let updateStreamInfo: @MainActor @Sendable (
            RTSPStreamPipeline.StreamInfo
        ) -> Void = { [weak previewStore] info in
            previewStore?.sourceWidth = info.width
            previewStore?.sourceHeight = info.height
            previewStore?.sourceCodec = info.codec
        }
        pipeline.onStreamInfo = { info in
            Task { @MainActor in updateStreamInfo(info) }
        }
    }

    private func wireSourceCallbacks() {
        sourceManager.onSourceConfigChanged = { [weak self] in
            self?.syncToActiveSource()
        }
        previewStore.onDemandChanged = { [weak self] in
            guard let self else { return }
            self.frameDispatcher.setPreviewEnabled(self.previewStore.isPreviewEnabled)
            self.demandChanged()
        }
        micDemand.onUpdate = { [weak self] in
            self?.audioDemandChanged()
        }
    }
}

// MARK: - Demand Tracking

private extension StreamCoordinator {
    func observeConsumerChanges() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()

        CFNotificationCenterAddObserver(
            center, observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let coord = Unmanaged<StreamCoordinator>.fromOpaque(observer)
                    .takeUnretainedValue()
                DispatchQueue.main.async { coord._hasConsumers = true; coord.demandChanged() }
            },
            LemurCamConfig.consumerStartedNotification, nil, .deliverImmediately
        )

        CFNotificationCenterAddObserver(
            center, observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let coord = Unmanaged<StreamCoordinator>.fromOpaque(observer)
                    .takeUnretainedValue()
                DispatchQueue.main.async { coord._hasConsumers = false; coord.demandChanged() }
            },
            LemurCamConfig.consumerStoppedNotification, nil, .deliverImmediately
        )

        // The extension posts nothing when it dies or its device is replaced, and
        // the model's discovery probe decides whether the sink stream starts: take
        // both from the model, so a consumer that is gone stops the stream and one
        // the sink serves gets frames.
        model.onExternalConsumerChange = { [weak self] hasConsumer in
            self?._hasConsumers = hasConsumer
            self?.demandChanged()
        }
    }

    func demandChanged() {
        reconcileDemand()
    }

    /// Microphone demand changed. The ring's producing flag tracks the mic directly;
    /// the shared pipeline is then reconciled like any other demand source.
    func audioDemandChanged() {
        if micDemand.hasConsumers {
            audioRing.beginProducing()
        } else {
            audioRing.endProducing()
        }
        reconcileDemand()
    }

    /// Bring the RTSP pipeline up or down only on demand *edges* — none→some resumes,
    /// some→none pauses. Toggling one consumer while another keeps demand satisfied is
    /// a no-op, so a live stream (and the mic audio riding on it) is never needlessly
    /// torn down and reconnected. Genuine reconnects (source switch, error retry) go
    /// through `syncToActiveSource()` directly and don't touch `lastDemand`.
    private func reconcileDemand() {
        let demand = hasDemand
        guard demand != lastDemand else { return }
        lastDemand = demand
        if demand {
            Log.rtsp.info("Demand detected — resuming RTSP pipeline")
            syncToActiveSource(force: true)
        } else {
            Log.rtsp.info("No demand — pausing RTSP pipeline")
            frameDispatcher.reset()
            cancelAllTasks()
            cancelPipeline()
            fallbackGenerator.stop()
            showActiveSourceIdle()
        }
    }

    /// Nothing needs the stream, so it is down on purpose rather than failed: show
    /// the active source as disconnected with no error, as a stream that ended is.
    /// A silent cancel fires no state change, so the status would otherwise keep
    /// saying "Connected", or "Reconnecting…" for a retry that was just cancelled.
    func showActiveSourceIdle() {
        guard let sourceID = currentSourceID else { return }
        sourceManager.updateErrorMessage(for: sourceID, message: nil)
        sourceManager.updateConnectionStatus(for: sourceID, status: .disconnected)
    }

    func cancelAllTasks() {
        retryTask?.cancel()
        retryTask = nil
        onvifTask?.cancel()
        onvifTask = nil
    }

    /// Start a pipeline connection and record it as the current one.
    func connectPipeline(url: String, credentials: SourceCredentials?) {
        currentConnection = pipeline.connect(url: url, credentials: credentials)
    }

    /// Cancel the pipeline's connection without a state change. State changes it
    /// already reported, still on their way to the main actor, are dropped.
    func cancelPipeline() {
        pipeline.cancelSilently()
        currentConnection = nil
    }
}

// MARK: - Connection Management

private extension StreamCoordinator {
    /// Bring the pipeline (or the "No camera available" placeholder) in line with the
    /// active source; `force` redoes it for the source already handled (launch, resume, retry).
    func syncToActiveSource(force: Bool = false) {
        let activeID = sourceManager.activeSourceID
        let activeSource = activeID.flatMap { id in
            sourceManager.sources.first(where: { $0.id == id })
        }

        // Any source's add/remove/edit lands here. When the active source itself is
        // unchanged, leave its tasks alone: cancelling first used to kill a pending
        // reconnect or ONVIF resolve, leaving the status at "Reconnecting" for good.
        if !force, activeID == currentSourceID, activeSource?.updatedAt == currentSourceUpdatedAt { return }
        cancelAllTasks()
        currentSourceID = activeID
        currentSourceUpdatedAt = activeSource?.updatedAt

        guard hasDemand else {
            Log.rtsp.info("No demand — skipping RTSP connection")
            showActiveSourceIdle()
            return
        }

        cancelPipeline()
        // A silent cancel fires no state change, so nothing else resets the jitter
        // buffer: its drain timer would keep re-sending the old camera's last frame.
        frameDispatcher.reset()
        fallbackGenerator.stop()
        previewStore.clear()

        guard let activeID,
              let source = sourceManager.sources.first(where: { $0.id == activeID }) else {
            Log.rtsp.info("No active source, starting fallback generator")
            fallbackGenerator.start()
            return
        }

        connectToSource(source, credentials: sourceManager.credentials(for: source.id))
    }

    func connectToSource(_ source: CameraSource, credentials: SourceCredentials?) {
        switch source.sourceType {
        case .rtsp(let info):
            Log.rtsp.info("Connecting to source '\(source.name)'")
            connectPipeline(url: info.url, credentials: credentials)
        case .onvif(let info):
            connectONVIFSource(info, sourceID: source.id, sourceName: source.name, credentials: credentials)
        }
    }

    func connectONVIFSource(
        _ info: ONVIFSourceInfo, sourceID: UUID, sourceName: String, credentials: SourceCredentials?
    ) {
        guard let token = info.selectedProfileToken else {
            if let streamURI = info.streamURI {
                Log.rtsp.info("Connecting to source '\(sourceName)'")
                connectPipeline(url: streamURI, credentials: credentials)
            } else {
                Log.rtsp.warning("ONVIF source has no stream URI, using fallback")
                sourceManager.updateConnectionStatus(for: sourceID, status: .error)
                fallbackGenerator.start()
            }
            return
        }

        Log.rtsp.info("Re-discovering ONVIF stream URI for '\(sourceName)'")
        // Resolving can take seconds; show what `.connecting` shows meanwhile.
        sourceManager.updateErrorMessage(for: sourceID, message: nil)
        sourceManager.updateConnectionStatus(for: sourceID, status: .connecting)
        fallbackGenerator.start(message: "Connecting in LemurCam")
        let params = ONVIFResolveParams(
            info: info, token: token, credentials: credentials,
            sourceID: sourceID, sourceName: sourceName, sourceManager: sourceManager,
            environment: onvifEnvironment
        )
        onvifTask = Task { [weak self] in
            let uri = await Self.resolveONVIFStreamURI(params: params)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.handleONVIFResolution(
                    uri: uri, info: info, sourceID: sourceID, credentials: credentials
                )
            }
        }
    }

    func handleONVIFResolution(
        uri: ONVIFStreamURIResult, info: ONVIFSourceInfo, sourceID: UUID, credentials: SourceCredentials?
    ) {
        guard currentSourceID == sourceID else { return }
        switch uri {
        case .success(let resolved):
            let target = Self.connectionTarget(forResolvedURI: resolved, savedCredentials: credentials)
            Log.rtsp.info("Connecting with resolved URI\(target.url == resolved ? "" : ", its login taken out")")
            connectPipeline(url: target.url, credentials: target.credentials)
        case .failure(let error):
            if let storedURI = info.streamURI {
                Log.rtsp.info("Falling back to stored URI")
                connectPipeline(url: storedURI, credentials: credentials)
                return
            }
            // Retry like any failed connect, so a camera that was offline when we
            // tried is picked up once it is back instead of staying in error.
            sourceManager.updateConnectionStatus(for: sourceID, status: .error)
            sourceManager.updateErrorMessage(for: sourceID, message: Self.onvifResolveFailureMessage(for: error))
            scheduleRetry()
        }
    }

    func handlePipelineStateChanged(_ state: RTSPStreamPipeline.State, connection: StreamConnectionID) {
        // State changes hop to the main actor, so one can arrive after its stream
        // was cancelled: by a pause, or by a source switch or reconnect that may
        // already have started the next connection. It is stale: it must not mark
        // the source connected or failed, nor schedule a reconnect nothing needs.
        guard connection == currentConnection, lastDemand else { return }
        if state != .streaming {
            frameDispatcher.reset()
            firstDecodedFrame.disarm()
        }
        guard let sourceID = currentSourceID else { return }

        let connectionStatus: ConnectionStatus
        switch state {
        case .idle, .disconnected:
            connectionStatus = .disconnected
            sourceManager.updateErrorMessage(for: sourceID, message: nil)
            previewStore.clear()
            fallbackGenerator.start(message: "Connection lost in LemurCam")
        case .connecting:
            connectionStatus = .connecting
            sourceManager.updateErrorMessage(for: sourceID, message: nil)
            fallbackGenerator.start(message: "Connecting in LemurCam")
        case .streaming:
            connectionStatus = .connected
            sourceManager.updateErrorMessage(for: sourceID, message: nil)
            // Connected is not yet working: the backoff resets on the first decoded frame.
            firstDecodedFrame.arm()
            fallbackGenerator.stop()
        case .error(let msg):
            connectionStatus = .error
            sourceManager.updateErrorMessage(for: sourceID, message: msg)
            previewStore.clear()
            fallbackGenerator.start(message: "Connection error in LemurCam")
        }

        sourceManager.updateConnectionStatus(for: sourceID, status: connectionStatus)
        if connectionStatus == .error || state == .disconnected {
            scheduleRetry()
        }
    }

    func scheduleRetry() {
        retryTask?.cancel()
        let delay = backoff.delayAfterFailure(of: .init(id: currentSourceID, updatedAt: currentSourceUpdatedAt))
        Log.rtsp.info("Scheduling reconnect in \(delay)s (attempt \(self.backoff.failures))")

        retryTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch { return }
            guard let self, !Task.isCancelled else { return }
            await MainActor.run {
                self.syncToActiveSource(force: true)
            }
        }

        if let sourceID = currentSourceID {
            sourceManager.updateConnectionStatus(for: sourceID, status: .reconnecting)
            fallbackGenerator.start(message: "Reconnecting in LemurCam")
        }
    }
}

// MARK: - Test Support

extension StreamCoordinator {
    /// Whether a reconnect is scheduled and not yet run or cancelled.
    var hasPendingRetry: Bool {
        retryTask != nil
    }

    /// Failures counted toward the next reconnect delay.
    var reconnectFailures: Int {
        backoff.failures
    }

    /// Whether decoded camera frames are being sent on to the virtual camera.
    var isForwardingCameraFrames: Bool {
        frameDispatcher.isForwardingFrames
    }

    /// The placeholder the app is sending to the virtual camera, if any.
    var placeholderMessage: String? {
        fallbackGenerator.placeholderMessage
    }

    /// Apply a camera consumer edge the way `observeConsumerChanges`' Darwin
    /// observers do, without posting the system-wide notification.
    func simulateCameraConsumerChange(active: Bool) {
        _hasConsumers = active
        demandChanged()
    }

    /// Apply a microphone consumer edge the way `VirtualMicDemand`'s Darwin
    /// observers do. Tests call this instead of posting the system-wide
    /// notification, which every other LemurCam process would also receive.
    func simulateAudioConsumerChange(active: Bool) {
        micDemand.consumerChanged(active: active)
    }

    /// Whether an app is using the virtual microphone, as last applied.
    var hasAudioConsumers: Bool {
        micDemand.hasConsumers
    }
}

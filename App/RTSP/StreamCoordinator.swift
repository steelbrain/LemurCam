import CoreVideo
import Foundation

@MainActor
internal final class StreamCoordinator {
    let model: LemurCamModel
    let previewStore: PreviewStore

    private let sourceManager: SourceManager
    private let pipeline = RTSPStreamPipeline()
    private let fallbackGenerator: FrameGenerator
    private let frameDispatcher: StreamFrameDispatcher
    private var currentSourceID: UUID?
    private var currentSourceUpdatedAt: Date?
    private var retryTask: Task<Void, Never>?
    private var onvifTask: Task<Void, Never>?
    private var connectionWatchdogTask: Task<Void, Never>?
    private var retryCount: Int = 0
    private var _hasConsumers: Bool = false
    private var _hasAudioConsumers: Bool = false
    private let audioRing = AudioRingBuffer()
    /// Whether the virtual mic is already running IO; injected for testability.
    private let audioConsumerProbe: () -> Bool
    /// The aggregate-demand value we last acted on. Demand changes that don't cross
    /// the zero/non-zero boundary leave an already-running stream alone, so toggling
    /// one consumer never tears down and reconnects a stream another consumer needs.
    private var lastDemand = false

    var hasDemand: Bool {
        _hasConsumers || _hasAudioConsumers || previewStore.isPreviewEnabled
    }

    init(
        sourceManager: SourceManager,
        audioConsumerProbe: @escaping () -> Bool = { VirtualMicProbe.isVirtualMicRunning() }
    ) {
        let streamModel = LemurCamModel()
        let previews = PreviewStore()

        self.model = streamModel
        self.previewStore = previews
        self.sourceManager = sourceManager
        self.audioConsumerProbe = audioConsumerProbe
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
        observeAudioConsumers()
    }

    func start() {
        frameDispatcher.setPreviewEnabled(previewStore.isPreviewEnabled)
        audioRing.open()
        _hasConsumers = LemurCamConfig.sharedDefaults?.bool(
            forKey: LemurCamConfig.hasExternalConsumersKey
        ) ?? false
        recoverAudioDemandOnLaunch()
        syncToActiveSource()
        // Record the demand state we just brought the pipeline into, so the first
        // consumer notification doesn't read as a spurious edge and reconnect.
        lastDemand = hasDemand
    }

    /// Recover audio demand missed at launch: a `consumerStarted` Darwin notification
    /// that fired before observers registered is not replayed, so seed from the device's
    /// running state and begin producing if in use. Split from `start()` for testability.
    func recoverAudioDemandOnLaunch() {
        _hasAudioConsumers = audioConsumerProbe()
        if _hasAudioConsumers { audioRing.beginProducing() }
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
        pipeline.onPixelBuffer = { pixelBuffer in
            dispatcher.handleDecodedFrame(pixelBuffer)
        }

        let ringBuffer = audioRing
        pipeline.onAudioPCM = { samples, frames in
            ringBuffer.write(samples, frames: frames)
        }

        let handleStateChange: @MainActor @Sendable (RTSPStreamPipeline.State) -> Void = { [weak self] state in
            self?.handlePipelineStateChanged(state)
        }
        pipeline.onStateChanged = { state in
            Task { @MainActor in handleStateChange(state) }
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
    }

    /// Observe the virtual-microphone driver's consumer notifications, mirroring the
    /// camera observers above. Split out so neither function exceeds the body-length
    /// limit; registered under the same token, removed wholesale in `deinit`.
    func observeAudioConsumers() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()

        CFNotificationCenterAddObserver(
            center, observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let coord = Unmanaged<StreamCoordinator>.fromOpaque(observer)
                    .takeUnretainedValue()
                DispatchQueue.main.async { coord._hasAudioConsumers = true; coord.audioDemandChanged() }
            },
            LEMUR_AUDIO_NOTIFY_CONSUMER_STARTED as CFString, nil, .deliverImmediately
        )

        CFNotificationCenterAddObserver(
            center, observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let coord = Unmanaged<StreamCoordinator>.fromOpaque(observer)
                    .takeUnretainedValue()
                DispatchQueue.main.async { coord._hasAudioConsumers = false; coord.audioDemandChanged() }
            },
            LEMUR_AUDIO_NOTIFY_CONSUMER_STOPPED as CFString, nil, .deliverImmediately
        )
    }

    func demandChanged() {
        reconcileDemand()
    }

    /// Microphone demand changed. The ring's producing flag tracks the mic directly;
    /// the shared pipeline is then reconciled like any other demand source.
    func audioDemandChanged() {
        if _hasAudioConsumers {
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
            currentSourceID = nil
            currentSourceUpdatedAt = nil
            syncToActiveSource()
        } else {
            Log.rtsp.info("No demand — pausing RTSP pipeline")
            frameDispatcher.reset()
            cancelAllTasks()
            pipeline.cancelSilently()
            fallbackGenerator.stop()
        }
    }

    func cancelAllTasks() {
        retryTask?.cancel()
        retryTask = nil
        onvifTask?.cancel()
        onvifTask = nil
        connectionWatchdogTask?.cancel()
        connectionWatchdogTask = nil
    }
}

// MARK: - Connection Management

private extension StreamCoordinator {
    func syncToActiveSource() {
        cancelAllTasks()

        let activeID = sourceManager.activeSourceID
        let activeSource = activeID.flatMap { id in
            sourceManager.sources.first(where: { $0.id == id })
        }

        if activeID == currentSourceID, activeSource?.updatedAt == currentSourceUpdatedAt { return }
        currentSourceID = activeID
        currentSourceUpdatedAt = activeSource?.updatedAt

        guard hasDemand else {
            Log.rtsp.info("No demand — skipping RTSP connection")
            return
        }

        pipeline.cancelSilently()
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
            pipeline.connect(url: info.url, credentials: credentials)
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
                pipeline.connect(url: streamURI, credentials: credentials)
            } else {
                Log.rtsp.warning("ONVIF source has no stream URI, using fallback")
                sourceManager.updateConnectionStatus(for: sourceID, status: .error)
                fallbackGenerator.start()
            }
            return
        }

        Log.rtsp.info("Re-discovering ONVIF stream URI for '\(sourceName)'")
        sourceManager.updateConnectionStatus(for: sourceID, status: .connecting)
        let params = ONVIFResolveParams(
            info: info, token: token, credentials: credentials,
            sourceID: sourceID, sourceName: sourceName, sourceManager: sourceManager
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
        uri: String?, info: ONVIFSourceInfo, sourceID: UUID, credentials: SourceCredentials?
    ) {
        guard currentSourceID == sourceID else { return }
        if let uri {
            Log.rtsp.info("Connecting with resolved URI")
            pipeline.connect(url: uri, credentials: credentials)
        } else if let storedURI = info.streamURI {
            Log.rtsp.info("Falling back to stored URI")
            pipeline.connect(url: storedURI, credentials: credentials)
        } else {
            sourceManager.updateConnectionStatus(for: sourceID, status: .error)
            sourceManager.updateErrorMessage(for: sourceID, message: "Could not reach camera")
            fallbackGenerator.start()
            return
        }
        scheduleConnectionWatchdog()
    }

    func handlePipelineStateChanged(_ state: RTSPStreamPipeline.State) {
        connectionWatchdogTask?.cancel()
        connectionWatchdogTask = nil
        if state != .streaming {
            frameDispatcher.reset()
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
            retryCount = 0
            fallbackGenerator.stop()
        case .error(let msg):
            connectionStatus = .error
            sourceManager.updateErrorMessage(for: sourceID, message: msg)
            previewStore.clear()
            fallbackGenerator.start(message: "Connection error in LemurCam")
        }

        sourceManager.updateConnectionStatus(for: sourceID, status: connectionStatus)
        if case .error = state {
            scheduleRetry()
        } else if case .disconnected = state {
            scheduleRetry()
        }
    }

    func scheduleConnectionWatchdog() {
        connectionWatchdogTask?.cancel()
        let timeout = Tuning.connectionTimeoutNs
        connectionWatchdogTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: timeout + 5_000_000_000)
            } catch { return }
            guard let self, !Task.isCancelled else { return }
            Log.rtsp.warning("Connection watchdog fired — pipeline unresponsive, forcing retry")
            self.scheduleRetry()
        }
    }

    func scheduleRetry() {
        retryTask?.cancel()
        let delay = min(Tuning.reconnectBackoffCap, Tuning.reconnectBackoffBase * pow(2.0, Double(retryCount)))
        retryCount += 1
        Log.rtsp.info("Scheduling reconnect in \(delay)s (attempt \(self.retryCount))")

        retryTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch { return }
            guard let self, !Task.isCancelled else { return }
            await MainActor.run {
                self.currentSourceID = nil
                self.currentSourceUpdatedAt = nil
                self.syncToActiveSource()
            }
        }

        if let sourceID = currentSourceID {
            sourceManager.updateConnectionStatus(for: sourceID, status: .reconnecting)
            fallbackGenerator.start(message: "Reconnecting in LemurCam")
        }
    }
}

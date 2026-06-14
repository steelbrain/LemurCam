import AVFoundation
import CoreMediaIO
import Foundation

internal final class LemurCamModel: Sendable {
    private let streamState = LemurCamStreamState()

    var isStreaming: Bool {
        streamState.isStreaming
    }

    var isReady: Bool {
        streamState.isReady
    }

    private let discoveryQueue = DispatchQueue(
        label: "com.steelbrain.LemurCam.discovery", qos: .userInitiated
    )

    init() {
        observeConsumerChanges()
    }

    deinit {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterRemoveEveryObserver(center, Unmanaged.passUnretained(self).toOpaque())
        streamState.clearStreamResources()
    }

    /// Begin (or restart) CMIO device discovery. Driven by `SetupCoordinator`'s
    /// `onCameraReady` callback once the camera extension is installed and the
    /// virtual camera device is live. Idempotent: a no-op once discovery succeeds.
    func beginDiscovery() {
        streamState.resetSetupRetries()
        scheduleRetry()
    }

    func sendSampleBuffer(_ buffer: CMSampleBuffer) {
        _ = streamState.enqueue(buffer)
    }

    // MARK: - Setup (discovery only)

    private func retrySetup() {
        switch streamState.prepareRetry(maxRetries: Tuning.maxSetupRetries) {
        case .idle:
            return
        case .failed:
            Log.ipc.error("setup failed after \(Tuning.maxSetupRetries) retries")
            return
        case .discover(let attempt):
            Log.ipc.info("retrying setup (attempt \(attempt))...")
            // Device enumeration initializes the CoreAudio HAL and blocks on coreaudiod,
            // which can stay busy for seconds after a reboot. Run it off the main thread
            // so it can never freeze the UI; the result is applied back on main.
            discoveryQueue.async { [weak self] in
                let result = Self.discoverDevice()
                DispatchQueue.main.async { self?.applyDiscoveryResult(result) }
            }
        }
    }

    /// Blocking device enumeration. Runs on `discoveryQueue`, never the main thread,
    /// because it initializes the CoreAudio HAL and can stall on a busy coreaudiod.
    /// Pure and state-free; the caller applies the result on the main thread.
    private static func discoverDevice() -> (deviceID: CMIODeviceID, streamID: CMIOStreamID)? {
        let allDevices = AVCaptureDevice
            .DiscoverySession(deviceTypes: [.external],
                              mediaType: .video,
                              position: .unspecified)
            .devices

        let matchesVCam: (AVCaptureDevice) -> Bool = { $0.localizedName == LemurCamConfig.virtualCameraName }
        guard let captureDevice = allDevices.first(where: matchesVCam) else {
            Log.ipc.warning("no capture device named '\(LemurCamConfig.virtualCameraName)'")
            return nil
        }

        let deviceIDs = CoreMediaIOUtil.getDeviceIDs()
        guard let deviceID = deviceIDs
            .first(where: { CoreMediaIOUtil.getDeviceUID(deviceID: $0) == captureDevice.uniqueID }) else {
            Log.ipc.warning("no matching deviceID")
            return nil
        }

        // Sink stream is at index 1, matching the order in ExtensionDeviceSource.init.
        // The CMIO C API does not expose stream direction for CMIOExtension-based streams,
        // so index-based lookup is the only reliable option.
        let streams = CoreMediaIOUtil.getStreams(deviceID: deviceID)
        if streams.count < 2 {
            Log.ipc.warning("streams count less than expected")
            return nil
        }

        return (deviceID, streams[1])
    }

    /// Applies a discovery result on the main thread, preserving single-threaded
    /// ownership of the device/stream/ready state. Reschedules a retry on a miss.
    private func applyDiscoveryResult(
        _ result: (deviceID: CMIODeviceID, streamID: CMIOStreamID)?
    ) {
        switch streamState.applyDiscoveryResult(result) {
        case .alreadyReady:
            return
        case .retry:
            scheduleRetry()
        case .ready:
            Log.ipc.info("Device discovered, waiting for consumer demand")

            // If consumers are already active (e.g. app restarted while Zoom
            // was using the camera), start immediately.
            let hasConsumers = LemurCamConfig.sharedDefaults?.bool(
                forKey: LemurCamConfig.hasExternalConsumersKey
            ) ?? false
            if hasConsumers {
                startStream()
            }
        }
    }

    private func scheduleRetry() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Tuning.setupRetryDelay) { [weak self] in
            self?.retrySetup()
        }
    }

    // MARK: - Stream Lifecycle

    private func startStream() {
        guard let snapshot = streamState.beginStarting() else {
            return
        }

        if snapshot.hasConnectedOnce {
            resumeStream(snapshot)
        } else {
            connectStream(snapshot)
        }
    }

    private func resumeStream(_ snapshot: LemurCamStreamState.StartSnapshot) {
        let res = CMIODeviceStartStream(snapshot.deviceID, snapshot.streamID)
        guard res == noErr else {
            streamState.finishStartingWithoutStream()
            Log.ipc.error("failed CMIODeviceStartStream: \(res)")
            return
        }

        streamState.markStreamResumed()
        Log.ipc.info("Sink stream started")
    }

    private func connectStream(_ snapshot: LemurCamStreamState.StartSnapshot) {
        streamState.clearStreamResources()

        let queueAlteredRegistration = CMIOStreamQueueAlteredRegistration()
        guard let queue = CoreMediaIOUtil.startStream(
            deviceID: snapshot.deviceID,
            streamID: snapshot.streamID,
            queueAlteredProc: queueAlteredRegistration.callback,
            queueAlteredRefCon: queueAlteredRegistration.refCon
        ) else {
            streamState.finishStartingWithoutStream()
            Log.ipc.error("CoreMediaIOUtil.startStream returned nil")
            return
        }

        let resources = CMIOStreamQueueResources(
            queue: SendableSimpleQueue(queue),
            queueAlteredRegistration: queueAlteredRegistration
        )
        streamState.markStreamConnected(resources: resources)
        Log.ipc.info("Sink stream started")
    }

    private func stopStream() {
        guard let snapshot = streamState.stopStreaming() else {
            return
        }

        CMIODeviceStopStream(snapshot.deviceID, snapshot.streamID)
        Log.ipc.info("Sink stream stopped (no consumers)")
    }

    // MARK: - Consumer Observation

    private func observeConsumerChanges() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()

        CFNotificationCenterAddObserver(
            center, observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let model = Unmanaged<LemurCamModel>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async { model.startStream() }
            },
            LemurCamConfig.consumerStartedNotification,
            nil, .deliverImmediately
        )

        CFNotificationCenterAddObserver(
            center, observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let model = Unmanaged<LemurCamModel>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async { model.stopStream() }
            },
            LemurCamConfig.consumerStoppedNotification,
            nil, .deliverImmediately
        )
    }
}

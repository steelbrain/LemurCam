import AVFoundation
import CoreMediaIO
import os

internal final class LemurCamModel: Sendable {
    private let streamState = LemurCamStreamState()

    var isStreaming: Bool {
        streamState.isStreaming
    }

    private let discoveryQueue = DispatchQueue(
        label: "com.steelbrain.LemurCam.discovery", qos: .userInitiated
    )

    /// Whether an external app is using the discovered device; read once discovery
    /// succeeds, before this app starts its own sink stream. Injected for testability.
    private let consumerProbe: @Sendable (CMIODeviceID) -> Bool

    /// Reads the CMIO device list after a change, on `discoveryQueue`. Injected for
    /// testability.
    private let deviceListReader: @Sendable () -> CMIODeviceList

    /// Sets a format on a sink stream (`SinkStreamFormatWriter`), on
    /// `discoveryQueue`. Injected for testability.
    private let formatWriter: @Sendable (StreamFormatSelection, CMIOStreamID) -> Void

    /// The user's Resolution and Frame Rate settings. Injected for testability.
    private let preferredFormat: @Sendable () -> StreamFormatSelection

    /// CMIO device-list listener, installed by the first `beginDiscovery()`. Its
    /// callbacks run on `discoveryQueue`, serialized with discovery itself.
    private let deviceListObserver = OSAllocatedUnfairLock<CMIODeviceListObserver?>(uncheckedState: nil)

    /// Keeps the extension's consumer notifications coming, set once by `init`.
    /// Released with the model, which removes their observers.
    private let consumerNotifications = OSAllocatedUnfairLock<AnyObject?>(uncheckedState: nil)

    private let externalConsumerHandler = OSAllocatedUnfairLock<(@MainActor @Sendable (Bool) -> Void)?>(
        initialState: nil
    )

    /// Told on the main thread whether an external app is using the virtual camera,
    /// each time this model learns it other than from the extension's consumer
    /// notifications: false when the cached device goes away, since an extension
    /// that crashes, is disabled, replaced or repaired never posts
    /// `consumerStopped`; and after each discovery of a new device, the consumer
    /// probe's answer, which also decides whether the sink stream starts. Set by
    /// `StreamCoordinator`, so its camera demand agrees with the sink stream.
    var onExternalConsumerChange: (@MainActor @Sendable (Bool) -> Void)? {
        get { externalConsumerHandler.withLock { $0 } }
        set { externalConsumerHandler.withLock { $0 = newValue } }
    }

    /// `consumerObserver` registers for the extension's consumer notifications,
    /// which start and stop the sink stream; tests pass one that never listens to
    /// the real, system-wide ones. Tests also pass a `formatWriter` that makes no
    /// CMIO calls on whatever real objects have their fake stream IDs.
    init(
        consumerProbe: @escaping @Sendable (CMIODeviceID) -> Bool = { id in
            CoreMediaIOUtil.hasExternalConsumer(deviceID: id)
        },
        deviceListReader: @escaping @Sendable () -> CMIODeviceList = { CoreMediaIOUtil.deviceList() },
        consumerObserver: ConsumerObserving = { ConsumerNotificationObserver.camera(onChange: $0) },
        formatWriter: @escaping @Sendable (StreamFormatSelection, CMIOStreamID) -> Void = { format, streamID in
            _ = SinkStreamFormatWriter.write(format, toStream: streamID)
        },
        preferredFormat: @escaping @Sendable () -> StreamFormatSelection = { LemurCamConfig.storedFormat }
    ) {
        self.consumerProbe = consumerProbe
        self.deviceListReader = deviceListReader
        self.formatWriter = formatWriter
        self.preferredFormat = preferredFormat
        let registration = consumerObserver { [weak self] active in
            if active {
                self?.startStream()
            } else {
                self?.stopStream()
            }
        }
        consumerNotifications.withLockUnchecked { $0 = registration }
    }

    deinit {
        consumerNotifications.withLockUnchecked { $0 = nil }
        streamState.clearStreamResources()
    }

    /// Begin (or re-run) CMIO device discovery. Driven by `SetupCoordinator`'s
    /// `onCameraReady` callback each time the camera extension becomes ready, which
    /// after a disable/re-enable or Repair can mean a new device. A pass that finds
    /// the cached device again leaves a live sink stream alone. From the first call
    /// on, device-list changes also drop stale IDs and rediscover on their own.
    func beginDiscovery() {
        streamState.requestDiscovery()
        observeDeviceListIfNeeded()
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
    /// Internal so tests can apply results without CMIO.
    @MainActor
    func applyDiscoveryResult(
        _ result: (deviceID: CMIODeviceID, streamID: CMIOStreamID)?
    ) {
        switch streamState.applyDiscoveryResult(result) {
        case .alreadyReady:
            return
        case .retry:
            scheduleRetry()
        case .ready(let deviceID):
            // This app hasn't told this device the settings yet: it just launched, or
            // the extension restarted and is back in its default format.
            if let streamID = result?.streamID {
                writePreferredFormat(to: streamID)
            }
            // If an app is already using the camera (e.g. this app relaunched while
            // Zoom had it open, or its consumerStarted notification fired before
            // discovery finished), start immediately. The app hasn't started its own
            // sink stream on this device yet, so "running somewhere" is external.
            // Only `.ready` probes: it means a new device, with no sink stream of ours.
            let hasConsumer = consumerProbe(deviceID)
            onExternalConsumerChange?(hasConsumer)
            if hasConsumer {
                Log.ipc.info("Device discovered with an active consumer, starting sink stream")
                startStream()
            } else {
                Log.ipc.info("Device discovered, waiting for consumer demand")
            }
        }
    }

    private func scheduleRetry() {
        // One armed timer at a time, however many triggers (onCameraReady, a missed
        // discovery, device-list changes) ask for a pass.
        guard streamState.claimRetrySchedule() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Tuning.setupRetryDelay) { [weak self] in
            self?.retrySetup()
        }
    }

    // MARK: - Device-list changes

    private func observeDeviceListIfNeeded() {
        let isObserving = deviceListObserver.withLockUnchecked { $0 != nil }
        guard !isObserving else { return }
        // Called on the main thread only, so no second observer can race this one in.
        let observer = CMIODeviceListObserver(queue: discoveryQueue) { [weak self] in
            self?.deviceListChanged()
        }
        deviceListObserver.withLockUnchecked { $0 = observer }
    }

    /// Runs on `discoveryQueue`, so the lookup is ordered with discovery passes:
    /// a discovery result applied after this change is never older than it.
    private func deviceListChanged() {
        let list = deviceListReader()
        DispatchQueue.main.async { [weak self] in
            self?.applyDeviceListChange(list)
        }
    }

    /// The extension was disabled, re-enabled, repaired, replaced or crashed: the
    /// cached device/stream IDs (and a sink stream stuck "streaming" because no
    /// `consumerStopped` arrived) belong to a device that no longer exists. Its
    /// consumers went with it. A list that couldn't be read or didn't identify the
    /// device keeps them, and is read again. Internal so tests can apply changes
    /// without CMIO.
    @MainActor
    func applyDeviceListChange(_ list: CMIODeviceList) {
        switch streamState.deviceListChanged(list) {
        case .unchanged:
            return
        case .recheck:
            Log.ipc.info("Couldn't identify the virtual camera in the CMIO device list; keeping its IDs, reading again")
            // Ordered with discovery passes and listener callbacks, like a change.
            discoveryQueue.asyncAfter(deadline: .now() + Tuning.setupRetryDelay) { [weak self] in
                self?.deviceListChanged()
            }
        case .deviceLost:
            Log.ipc.info("Virtual camera device went away; dropped its cached CMIO IDs and sink stream")
            onExternalConsumerChange?(false)
        case .deviceReplaced:
            Log.ipc.info("Virtual camera device was replaced; dropped its cached CMIO IDs and re-running discovery")
            onExternalConsumerChange?(false)
            scheduleRetry()
        case .rediscover:
            Log.ipc.info("Virtual camera device appeared; running discovery")
            scheduleRetry()
        }
    }
}

// MARK: - Format

extension LemurCamModel {
    /// Set the user's Resolution and Frame Rate settings on the cached device's
    /// sink stream, after they change. The extension applies them to the camera
    /// now if no app is using it, otherwise once the last app stops. Without a
    /// cached device this does nothing: discovery sets them on the device it finds.
    @MainActor
    func applyPreferredFormat() {
        guard let streamID = streamState.sinkStreamID else { return }
        writePreferredFormat(to: streamID)
    }

    /// The CMIO calls go to the extension and wait for it, so they run on
    /// `discoveryQueue`, in order with discovery, never on the main thread.
    private func writePreferredFormat(to streamID: CMIOStreamID) {
        let format = preferredFormat()
        let writer = formatWriter
        discoveryQueue.async {
            writer(format, streamID)
        }
    }
}

// MARK: - Stream Lifecycle

private extension LemurCamModel {
    func startStream() {
        guard let snapshot = streamState.beginStarting() else {
            return
        }

        if snapshot.hasConnectedOnce {
            resumeStream(snapshot)
        } else {
            connectStream(snapshot)
        }
    }

    func resumeStream(_ snapshot: LemurCamStreamState.StartSnapshot) {
        let res = CMIODeviceStartStream(snapshot.deviceID, snapshot.streamID)
        guard res == noErr else {
            streamState.finishStartingWithoutStream()
            Log.ipc.error("failed CMIODeviceStartStream: \(res)")
            return
        }

        streamState.markStreamResumed()
        Log.ipc.info("Sink stream started")
    }

    func connectStream(_ snapshot: LemurCamStreamState.StartSnapshot) {
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

    func stopStream() {
        guard let snapshot = streamState.stopStreaming() else {
            return
        }

        CMIODeviceStopStream(snapshot.deviceID, snapshot.streamID)
        Log.ipc.info("Sink stream stopped (no consumers)")
    }
}

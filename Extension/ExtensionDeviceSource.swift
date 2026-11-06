import CoreMediaIO
import Foundation

internal final class ExtensionDeviceSource: NSObject, CMIOExtensionDeviceSource {

    private(set) var device: CMIOExtensionDevice?

    private var _streamSource: ExtensionStreamSource?

    private var _sinkStreamSource: ExtensionSinkStreamSource?

    private let _timerQueue = DispatchQueue(
        label: "timerQueue", qos: .userInteractive, attributes: [],
        autoreleaseFrequency: .workItem, target: .global(qos: .userInteractive)
    )

    private var _sinkClientsObservation: NSKeyValueObservation?
    /// Starts in the default format. The user's settings can't be read here: the
    /// extension runs as another user, with app-group defaults of its own. The app
    /// sets them through the sink stream once it finds the device.
    private let runtime = ExtensionDeviceRuntime(initialFormat: LemurCamConfig.defaultFormat)

    init(localizedName: String) {
        super.init()

        let createdDevice = createDevice(localizedName: localizedName)
        self.device = createdDevice

        createStreams(device: createdDevice, formats: ExtensionStreamFormats.make())

        if let sourceStream = _streamSource?.stream {
            let placeholder = PlaceholderFrame.render(at: runtime.activeFormat.resolution)
            if placeholder == nil {
                Log.ext.error("Placeholder render failed; consumers see only live frames")
            }
            runtime.configure(sourceStream: sourceStream, placeholder: placeholder)
        }
        observeSinkClients()
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        return [.deviceTransportType, .deviceModel]
    }

    // swiftlint:disable unneeded_throws_rethrows
    func deviceProperties(
        forProperties properties: Set<CMIOExtensionProperty>
    ) throws -> CMIOExtensionDeviceProperties {
        let deviceProperties = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) {
            deviceProperties.transportType = kIOAudioDeviceTransportTypeVirtual
        }
        if properties.contains(.deviceModel) {
            deviceProperties.model = LemurCamConfig.virtualCameraName
        }
        return deviceProperties
    }
    // swiftlint:enable unneeded_throws_rethrows

    // swiftlint:disable:next unneeded_throws_rethrows
    func setDeviceProperties(_: CMIOExtensionDeviceProperties) throws {

        // Handle settable properties here.
    }

    func startStreaming() {
        // The consumer is counted and announced even without a placeholder, so the
        // app starts feeding frames and they are forwarded; only the placeholder
        // timer needs the rendered placeholder.
        let result = runtime.startStreaming(timerQueue: _timerQueue)
        postConsumerNotification(started: true)
        result.timer?.resume()
    }

    func stopStreaming() {
        let result = runtime.stopStreaming()
        postConsumerNotification(started: result.hasConsumers)
        result.timer?.cancel()
    }

    func startSinkStreaming() {
        _sinkStreamSource?.consumeSampleBuffer = { [runtime] buffer in
            runtime.forwardSinkFrame(buffer)
        }
        runtime.startSinking()
    }

    func stopSinkStreaming() {
        guard runtime.stopSinking() else { return }
        _sinkStreamSource?.consumeSampleBuffer = nil
        Log.ext.info("Sink streaming stopped")
    }
}

// MARK: - Private Helpers

private extension ExtensionDeviceSource {
    func createDevice(localizedName: String) -> CMIOExtensionDevice {
        guard let deviceID = UUID(uuidString: LemurCamConfig.deviceID) else {
            fatalError("Invalid device UUID string: \(LemurCamConfig.deviceID)")
        }
        return CMIOExtensionDevice(
            localizedName: localizedName, deviceID: deviceID,
            legacyDeviceID: nil, source: self
        )
    }

    /// The source stream first and the sink second: the app finds the sink at
    /// stream index 1.
    func createStreams(device: CMIOExtensionDevice, formats: [CMIOExtensionStreamFormat]) {
        guard let videoID = UUID(uuidString: LemurCamConfig.videoID) else {
            fatalError("Invalid video UUID string: \(LemurCamConfig.videoID)")
        }
        _streamSource = ExtensionStreamSource(
            localizedName: "\(LemurCamConfig.virtualCameraName).Video",
            streamID: videoID, formats: formats, device: device, runtime: runtime
        )

        guard let sinkStreamID = UUID(uuidString: LemurCamConfig.sinkStreamID) else {
            fatalError("Invalid sink stream UUID string: \(LemurCamConfig.sinkStreamID)")
        }
        _sinkStreamSource = ExtensionSinkStreamSource(
            localizedName: "\(LemurCamConfig.virtualCameraName).Video.Sink",
            streamID: sinkStreamID, formats: formats, device: device, runtime: runtime
        )
        do {
            guard let streamSource = _streamSource,
                  let sinkStreamSource = _sinkStreamSource,
                  let sourceStream = streamSource.stream,
                  let sinkStream = sinkStreamSource.stream else {
                fatalError("Failed to unwrap stream sources after creation")
            }
            try device.addStream(sourceStream)
            try device.addStream(sinkStream)
        } catch {
            fatalError("Failed to add stream: \(error.localizedDescription)")
        }
    }

    func observeSinkClients() {
        guard let sinkStream = _sinkStreamSource?.stream else { return }
        let source = SendableUnretainedReference(self)
        _sinkClientsObservation = sinkStream.observe(
            \.streamingClients, options: [.new]
        ) { _, change in
            if let clients = change.newValue, clients.isEmpty {
                Log.ext.info("Sink stream has no clients, resetting sink state")
                source.withValue {
                    $0.stopSinkStreaming()
                }
            }
        }
    }

    func postConsumerNotification(started: Bool) {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let name = started
            ? LemurCamConfig.consumerStartedNotification
            : LemurCamConfig.consumerStoppedNotification
        CFNotificationCenterPostNotification(center, CFNotificationName(name), nil, nil, true)
    }
}

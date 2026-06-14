import CoreMediaIO
import Foundation
import os

internal final class ExtensionDeviceSource: NSObject, CMIOExtensionDeviceSource {

    private(set) var device: CMIOExtensionDevice?

    private var _streamSource: ExtensionStreamSource?

    private var _sinkStreamSource: ExtensionSinkStreamSource?

    private let _timerQueue = DispatchQueue(
        label: "timerQueue", qos: .userInteractive, attributes: [],
        autoreleaseFrequency: .workItem, target: .global(qos: .userInteractive)
    )

    private var _sinkClientsObservation: NSKeyValueObservation?
    private let runtime = ExtensionDeviceRuntime()

    private let _width: Int32
    private let _height: Int32

    init(localizedName: String) {
        let resolution = LemurCamConfig.storedResolution
        _width = resolution.width
        _height = resolution.height

        super.init()

        let (createdDevice, videoDescription) = createDevice(localizedName: localizedName)
        self.device = createdDevice

        let videoStreamFormat = createStreamFormat(videoDescription: videoDescription)
        createStreams(device: createdDevice, streamFormat: videoStreamFormat)

        if let sourceStream = _streamSource?.stream {
            runtime.configure(
                sourceStream: sourceStream,
                videoDescription: videoDescription,
                placeholderBuffer: renderPlaceholder()
            )
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
        let result = runtime.startStreaming(timerQueue: _timerQueue)
        guard result.didStart else { return }
        LemurCamConfig.sharedDefaults?.set(true, forKey: LemurCamConfig.hasExternalConsumersKey)
        postConsumerNotification(started: true)
        result.timer?.resume()
    }

    func stopStreaming() {
        let result = runtime.stopStreaming()
        LemurCamConfig.sharedDefaults?.set(result.hasConsumers, forKey: LemurCamConfig.hasExternalConsumersKey)
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
    func createDevice(
        localizedName: String
    ) -> (CMIOExtensionDevice, CMFormatDescription) {
        guard let deviceID = UUID(uuidString: LemurCamConfig.deviceID) else {
            fatalError("Invalid device UUID string: \(LemurCamConfig.deviceID)")
        }
        let device = CMIOExtensionDevice(
            localizedName: localizedName, deviceID: deviceID,
            legacyDeviceID: nil, source: self
        )

        var videoDescription: CMFormatDescription?
        let fmtStatus = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            width: _width, height: _height,
            extensions: nil, formatDescriptionOut: &videoDescription
        )
        if fmtStatus != noErr {
            fatalError("Failed to create video format description: \(fmtStatus)")
        }
        guard let videoDescription else {
            fatalError("Failed to unwrap video format description after creation")
        }
        return (device, videoDescription)
    }

    func createStreamFormat(videoDescription: CMFormatDescription) -> CMIOExtensionStreamFormat {
        let frameDuration = CMTime(value: 1, timescale: Int32(LemurCamConfig.frameRate))
        return CMIOExtensionStreamFormat(
            formatDescription: videoDescription, maxFrameDuration: frameDuration,
            minFrameDuration: frameDuration, validFrameDurations: nil
        )
    }

    func createStreams(device: CMIOExtensionDevice, streamFormat: CMIOExtensionStreamFormat) {
        guard let videoID = UUID(uuidString: LemurCamConfig.videoID) else {
            fatalError("Invalid video UUID string: \(LemurCamConfig.videoID)")
        }
        _streamSource = ExtensionStreamSource(
            localizedName: "\(LemurCamConfig.virtualCameraName).Video",
            streamID: videoID, streamFormat: streamFormat, device: device
        )

        guard let sinkStreamID = UUID(uuidString: LemurCamConfig.sinkStreamID) else {
            fatalError("Invalid sink stream UUID string: \(LemurCamConfig.sinkStreamID)")
        }
        _sinkStreamSource = ExtensionSinkStreamSource(
            localizedName: "\(LemurCamConfig.virtualCameraName).Video.Sink",
            streamID: sinkStreamID, streamFormat: streamFormat, device: device
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

    func renderPlaceholder() -> CVPixelBuffer? {
        PlaceholderRenderer.render(
            text: "LemurCam is not running",
            width: Int(_width),
            height: Int(_height),
            fontSize: 64.0
        )
    }
}

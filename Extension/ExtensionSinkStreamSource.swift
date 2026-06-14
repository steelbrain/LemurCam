import CoreMedia
import CoreMediaIO
import Foundation
import os

internal final class ExtensionSinkStreamSource: NSObject, CMIOExtensionStreamSource {
    private struct ConsumeContext: Sendable {
        let state: ExtensionSinkStreamState
        let stream: SendableRetainedReference<CMIOExtensionStream>
        let deviceSource: SendableRetainedReference<ExtensionDeviceSource>
        let consumeQueue: DispatchQueue
        let generation: UInt64
    }

    private struct ConsumeCompletion {
        let sampleBuffer: CMSampleBuffer?
        let sampleBufferSequenceNumber: UInt64
        let error: (any Error)?
    }

    private let state = ExtensionSinkStreamState()

    var consumeSampleBuffer: SinkSampleBufferHandler? {
        get {
            state.consumeSampleBuffer
        }
        set {
            state.consumeSampleBuffer = newValue
        }
    }

    private(set) var stream: CMIOExtensionStream?
    let device: CMIOExtensionDevice
    private let _streamFormat: CMIOExtensionStreamFormat

    /// Serial queue used to defer the next sink pull after an empty completion,
    /// so the consume loop throttles instead of busy-polling the producer.
    private let consumeQueue = DispatchQueue(
        label: "cam.lemur.app.extension.sinkConsume", qos: .userInteractive
    )

    init(localizedName: String, streamID: UUID, streamFormat: CMIOExtensionStreamFormat, device: CMIOExtensionDevice) {
        self.device = device
        self._streamFormat = streamFormat
        super.init()
        self.stream = CMIOExtensionStream(localizedName: localizedName,
                                          streamID: streamID,
                                          direction: .sink,
                                          clockType: .hostTime,
                                          source: self)
    }

    var formats: [CMIOExtensionStreamFormat] {
        return [_streamFormat]
    }
    var activeFormatIndex: Int {
        get {
            state.activeFormatIndex
        }
        set {
            if let oldValue = state.setActiveFormatIndex(newValue) {
                Log.ext.error("Invalid activeFormatIndex, reverting to \(oldValue)")
            }
        }
    }
    var availableProperties: Set<CMIOExtensionProperty> {
        [
            .streamActiveFormatIndex,
            .streamFrameDuration,
            .streamSinkBufferQueueSize,
            .streamSinkBuffersRequiredForStartup
        ]
    }
    // swiftlint:disable unneeded_throws_rethrows
    func streamProperties(
        forProperties properties: Set<CMIOExtensionProperty>
    ) throws -> CMIOExtensionStreamProperties {
        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            streamProperties.activeFormatIndex = activeFormatIndex
        }
        if properties.contains(.streamFrameDuration) {
            let frameDuration = CMTime(value: 1, timescale: Int32(LemurCamConfig.frameRate))
            streamProperties.frameDuration = frameDuration
        }
        if properties.contains(.streamSinkBufferQueueSize) {
            streamProperties.sinkBufferQueueSize = Tuning.sinkBufferQueueSize
        }
        if properties.contains(.streamSinkBuffersRequiredForStartup) {
            streamProperties.sinkBuffersRequiredForStartup = Tuning.sinkBuffersForStartup
        }
        return streamProperties
    }
    // swiftlint:enable unneeded_throws_rethrows

    // swiftlint:disable:next unneeded_throws_rethrows
    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let newActiveFormatIndex = streamProperties.activeFormatIndex {
            activeFormatIndex = newActiveFormatIndex
        }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        state.setClient(client)
        // An opportunity to inspect the client info and decide if it should be allowed to start the stream.
        return true
    }

    func startStream() throws {
        guard let deviceSource = device.source as? ExtensionDeviceSource else {
            Log.ext.error("startStream: unexpected device source type")
            throw NSError(domain: "cam.lemur.app.extension", code: -1)
        }
        state.start()
        deviceSource.startSinkStreaming()
        subscribe(deviceSource: deviceSource)
    }

    func stopStream() throws {
        state.stop()
        guard let deviceSource = device.source as? ExtensionDeviceSource else {
            Log.ext.error("stopStream: unexpected device source type")
            throw NSError(domain: "cam.lemur.app.extension", code: -1)
        }
        deviceSource.stopSinkStreaming()
    }

    private func subscribe(deviceSource: ExtensionDeviceSource) {
        guard let stream else { return }
        Self.subscribe(
            state: state,
            stream: SendableRetainedReference(stream),
            deviceSource: SendableRetainedReference(deviceSource),
            consumeQueue: consumeQueue
        )
    }

    private static func subscribe(
        state: ExtensionSinkStreamState,
        stream: SendableRetainedReference<CMIOExtensionStream>,
        deviceSource: SendableRetainedReference<ExtensionDeviceSource>,
        consumeQueue: DispatchQueue
    ) {
        guard let snapshot = state.subscriptionSnapshot() else { return }
        let context = ConsumeContext(
            state: state,
            stream: stream,
            deviceSource: deviceSource,
            consumeQueue: consumeQueue,
            generation: snapshot.generation
        )

        stream.withValue { streamValue in
            snapshot.client.withValue { client in
                streamValue.consumeSampleBuffer(
                    from: client
                ) { sampleBuffer, sampleBufferSequenceNumber, _, _, error in
                    handleConsumeResult(
                        context: context,
                        completion: ConsumeCompletion(
                            sampleBuffer: sampleBuffer,
                            sampleBufferSequenceNumber: sampleBufferSequenceNumber,
                            error: error
                        )
                    )
                }
            }
        }
    }

    private static func handleConsumeResult(
        context: ConsumeContext,
        completion: ConsumeCompletion
    ) {
        if completion.error == nil, let sampleBuffer = completion.sampleBuffer {
            context.state.deliver(sampleBuffer)
            context.stream.withValue { stream in
                let presentationNanoSec = UInt64(sampleBuffer.presentationTimeStamp.seconds * Double(NSEC_PER_SEC))
                let output = CMIOExtensionScheduledOutput(sequenceNumber: completion.sampleBufferSequenceNumber,
                                                          hostTimeInNanoseconds: presentationNanoSec)
                stream.notifyScheduledOutputChanged(output)
            }
        }
        // Empty completions (the producer has no frame ready) must not re-arm
        // immediately: that turns the pull into a busy XPC poll that pegs CPU in
        // both this extension and the app. Throttle empty polls to one frame
        // interval; real frames still re-arm immediately so bursts drain fast.
        switch SinkConsumeScheduler.action(hasBuffer: completion.sampleBuffer != nil,
                                           hasError: completion.error != nil,
                                           frameRate: LemurCamConfig.frameRate) {
        case .stop:
            Log.ext.info("Sink client disconnected: \(completion.error?.localizedDescription ?? "unknown error")")
            context.state.markDisconnected()
            context.deviceSource.withValue {
                $0.stopSinkStreaming()
            }
        case .resubscribeImmediately:
            subscribe(
                state: context.state,
                stream: context.stream,
                deviceSource: context.deviceSource,
                consumeQueue: context.consumeQueue
            )
        case .resubscribeAfter(let nanoseconds):
            context.consumeQueue.asyncAfter(deadline: .now() + .nanoseconds(Int(nanoseconds))) {
                guard context.state.isCurrent(generation: context.generation) else { return }
                subscribe(
                    state: context.state,
                    stream: context.stream,
                    deviceSource: context.deviceSource,
                    consumeQueue: context.consumeQueue
                )
            }
        }
    }
}

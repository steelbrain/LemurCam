import CoreMedia
import CoreMediaIO
import Foundation

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
    private let _formats: [CMIOExtensionStreamFormat]
    private let runtime: ExtensionDeviceRuntime

    /// Serial queue used to defer the next sink pull after an empty completion,
    /// so the consume loop throttles instead of busy-polling the producer.
    private let consumeQueue = DispatchQueue(
        label: "cam.lemur.app.extension.sinkConsume", qos: .userInteractive
    )

    /// The sink offers the source's formats so the app can name its default with
    /// the standard format and frame-rate properties: what the app sets here
    /// becomes the source stream's default (`ExtensionDeviceRuntime.setDefaultFormat`).
    /// It takes the app's frames at any size, whatever format is active.
    init(
        localizedName: String,
        streamID: UUID,
        formats: [CMIOExtensionStreamFormat],
        device: CMIOExtensionDevice,
        runtime: ExtensionDeviceRuntime
    ) {
        self.device = device
        self._formats = formats
        self.runtime = runtime
        super.init()
        self.stream = CMIOExtensionStream(localizedName: localizedName,
                                          streamID: streamID,
                                          direction: .sink,
                                          clockType: .hostTime,
                                          source: self)
    }

    var formats: [CMIOExtensionStreamFormat] {
        return _formats
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
        let preferred = runtime.preferredFormat
        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            streamProperties.activeFormatIndex = preferred.formatIndex
        }
        if properties.contains(.streamFrameDuration) {
            streamProperties.frameDuration = preferred.frameDuration
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
        runtime.setDefaultFormat(ExtensionStreamFormats.request(in: streamProperties, stream: "sink"))
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
        let generation = state.start()
        deviceSource.startSinkStreaming()
        subscribe(deviceSource: deviceSource, generation: generation)
    }

    func stopStream() throws {
        state.stop()
        guard let deviceSource = device.source as? ExtensionDeviceSource else {
            Log.ext.error("stopStream: unexpected device source type")
            throw NSError(domain: "cam.lemur.app.extension", code: -1)
        }
        deviceSource.stopSinkStreaming()
    }

    private func subscribe(deviceSource: ExtensionDeviceSource, generation: UInt64) {
        guard let stream else { return }
        Self.subscribe(
            context: ConsumeContext(
                state: state,
                stream: SendableRetainedReference(stream),
                deviceSource: SendableRetainedReference(deviceSource),
                consumeQueue: consumeQueue,
                generation: generation
            )
        )
    }

    /// Issue one consume request for `context.generation`. A no-op once that
    /// session has ended, so a loop never outlives (or doubles up on) its session.
    private static func subscribe(context: ConsumeContext) {
        guard let client = context.state.client(forGeneration: context.generation) else { return }

        context.stream.withValue { streamValue in
            client.withValue { client in
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
        // Every branch is gated on the completion's generation (see
        // SinkCompletionAction.discardStale): after a quick stop/start, a completion
        // from the old session must neither stop the new one nor start a second loop.
        //
        // Empty completions (the producer has no frame ready) must not re-arm
        // immediately: that turns the pull into a busy XPC poll that pegs CPU in
        // both this extension and the app. Throttle empty polls to half a frame
        // interval (SinkConsumeScheduler); real frames still re-arm immediately so
        // bursts drain fast.
        switch context.state.completionAction(
            generation: context.generation,
            hasBuffer: completion.sampleBuffer != nil,
            hasError: completion.error != nil,
            // The fastest rate any format allows, whatever the active one, so a
            // frame never waits long in the queue; the source stream does the pacing.
            frameRate: StreamFormatTable.fastestFrameRate.rawValue
        ) {
        case .discardStale:
            return
        case .proceed(.stop):
            guard context.state.markDisconnected(ifCurrent: context.generation) else { return }
            Log.ext.info("Sink client disconnected: \(completion.error?.localizedDescription ?? "unknown error")")
            context.deviceSource.withValue {
                $0.stopSinkStreaming()
            }
        case .proceed(.resubscribeImmediately):
            if let sampleBuffer = completion.sampleBuffer {
                forward(sampleBuffer, sequenceNumber: completion.sampleBufferSequenceNumber, context: context)
            }
            subscribe(context: context)
        case .proceed(.resubscribeAfter(let nanoseconds)):
            context.consumeQueue.asyncAfter(deadline: .now() + .nanoseconds(Int(nanoseconds))) {
                subscribe(context: context)
            }
        }
    }

    /// Hand a live buffer to the device (which forwards it to the source stream)
    /// and report it to the client as output.
    private static func forward(_ sampleBuffer: CMSampleBuffer, sequenceNumber: UInt64, context: ConsumeContext) {
        context.state.deliver(sampleBuffer)
        context.stream.withValue { stream in
            // The producer sets this timestamp; an invalid/NaN/negative one must not trap.
            let presentationNanoSec = HostTimeNanoseconds.nanosecondsOrNow(sampleBuffer.presentationTimeStamp)
            let output = CMIOExtensionScheduledOutput(sequenceNumber: sequenceNumber,
                                                      hostTimeInNanoseconds: presentationNanoSec)
            stream.notifyScheduledOutputChanged(output)
        }
    }
}

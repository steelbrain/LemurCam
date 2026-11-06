import CoreMediaIO
import Foundation

/// The stream other apps capture from. It offers every resolution at every frame
/// rate (`ExtensionStreamFormats`); an app that picks a format or frame rate gets
/// it at once, and frames are scaled and paced to it (`ExtensionDeviceRuntime`).
internal class ExtensionStreamSource: NSObject, CMIOExtensionStreamSource {

    private(set) var stream: CMIOExtensionStream?

    let device: CMIOExtensionDevice

    private let _formats: [CMIOExtensionStreamFormat]

    private let runtime: ExtensionDeviceRuntime

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
        self.stream = CMIOExtensionStream(
            localizedName: localizedName, streamID: streamID,
            direction: .source, clockType: .hostTime, source: self
        )
    }

    var formats: [CMIOExtensionStreamFormat] {
        return _formats
    }

    var availableProperties: Set<CMIOExtensionProperty> {

        return [.streamActiveFormatIndex, .streamFrameDuration]
    }

    // swiftlint:disable unneeded_throws_rethrows
    func streamProperties(
        forProperties properties: Set<CMIOExtensionProperty>
    ) throws -> CMIOExtensionStreamProperties {

        let active = runtime.activeFormat
        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            streamProperties.activeFormatIndex = active.formatIndex
        }
        if properties.contains(.streamFrameDuration) {
            streamProperties.frameDuration = active.frameDuration
        }

        return streamProperties
    }
    // swiftlint:enable unneeded_throws_rethrows

    // swiftlint:disable:next unneeded_throws_rethrows
    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        runtime.setSourceFormat(ExtensionStreamFormats.request(in: streamProperties, stream: "source"))
    }

    func authorizedToStartStream(for _: CMIOExtensionClient) -> Bool {

        // An opportunity to inspect the client info and decide if it should be allowed to start the stream.
        return true
    }

    func startStream() throws {
        guard let deviceSource = device.source as? ExtensionDeviceSource else {
            Log.ext.error("startStream: unexpected device source type")
            throw NSError(domain: "cam.lemur.app.extension", code: -1)
        }
        deviceSource.startStreaming()
    }

    func stopStream() throws {
        guard let deviceSource = device.source as? ExtensionDeviceSource else {
            Log.ext.error("stopStream: unexpected device source type")
            throw NSError(domain: "cam.lemur.app.extension", code: -1)
        }
        deviceSource.stopStreaming()
    }
}

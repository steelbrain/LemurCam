import CoreMediaIO
import Foundation
import os

internal class ExtensionStreamSource: NSObject, CMIOExtensionStreamSource {

    private(set) var stream: CMIOExtensionStream?

    let device: CMIOExtensionDevice

    private let _formats: [CMIOExtensionStreamFormat]

    init(localizedName: String, streamID: UUID, streamFormat: CMIOExtensionStreamFormat, device: CMIOExtensionDevice) {

        self.device = device

        // Advertise multiple resolutions so consuming apps can find a compatible format
        let frameRate = Int32(LemurCamConfig.frameRate)
        var allFormats: [CMIOExtensionStreamFormat] = []
        for resolution in LemurCamConfig.Resolution.allCases {
            var desc: CMFormatDescription?
            CMVideoFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                codecType: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                width: resolution.width,
                height: resolution.height,
                extensions: nil,
                formatDescriptionOut: &desc
            )
            if let desc {
                allFormats.append(CMIOExtensionStreamFormat(
                    formatDescription: desc,
                    maxFrameDuration: CMTime(value: 1, timescale: frameRate),
                    minFrameDuration: CMTime(value: 1, timescale: frameRate),
                    validFrameDurations: nil
                ))
            }
        }
        _formats = allFormats.isEmpty ? [streamFormat] : allFormats

        super.init()
        self.stream = CMIOExtensionStream(
            localizedName: localizedName, streamID: streamID,
            direction: .source, clockType: .hostTime, source: self
        )
    }

    var formats: [CMIOExtensionStreamFormat] {
        return _formats
    }

    var activeFormatIndex: Int = 0 {
        didSet {
            if activeFormatIndex >= _formats.count {
                Log.ext.error("Invalid activeFormatIndex \(activeFormatIndex), reverting to \(oldValue)")
                activeFormatIndex = oldValue
            }
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> {

        return [.streamActiveFormatIndex, .streamFrameDuration]
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

        return streamProperties
    }
    // swiftlint:enable unneeded_throws_rethrows

    // swiftlint:disable:next unneeded_throws_rethrows
    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {

        if let newActiveFormatIndex = streamProperties.activeFormatIndex {
            activeFormatIndex = newActiveFormatIndex
        }
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

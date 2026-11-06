import CoreMedia
import CoreMediaIO

/// The extension's side of `StreamFormatTable`: the `CMIOExtensionStreamFormat`s
/// both streams advertise, and the conversions between CMIO stream properties and
/// the table's formats.
internal enum ExtensionStreamFormats {
    /// What a client asked for in one `setStreamProperties` call; nil where it
    /// asked for nothing, or for a value no format has.
    internal struct Request {
        let resolution: LemurCamConfig.Resolution?
        let frameRate: LemurCamConfig.FrameRate?
    }

    /// One format per resolution, in `StreamFormatTable.resolutions` order so a
    /// format index names a resolution. Each allows exactly the table's frame
    /// durations (`validFrameDurations`), between the fastest and slowest of them.
    static func make() -> [CMIOExtensionStreamFormat] {
        StreamFormatTable.resolutions.map { resolution in
            var description: CMFormatDescription?
            let status = CMVideoFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                codecType: StreamFormatTable.pixelFormat,
                width: resolution.width,
                height: resolution.height,
                extensions: nil,
                formatDescriptionOut: &description
            )
            // A missing format would shift every index after it onto the wrong resolution.
            guard status == noErr, let description else {
                fatalError("Failed to create the \(resolution.rawValue) format description: \(status)")
            }
            return CMIOExtensionStreamFormat(
                formatDescription: description,
                maxFrameDuration: StreamFormatTable.maxFrameDuration,
                minFrameDuration: StreamFormatTable.minFrameDuration,
                validFrameDurations: StreamFormatTable.validFrameDurations
            )
        }
    }

    /// The active format index and frame duration of `format`, as a stream reports them.
    static func properties(of format: StreamFormatSelection) -> CMIOExtensionStreamProperties {
        let properties = CMIOExtensionStreamProperties(dictionary: [:])
        properties.activeFormatIndex = format.formatIndex
        properties.frameDuration = format.frameDuration
        return properties
    }

    /// The format index and frame duration a client set, checked against the
    /// table. A value no format has is logged and left out, so the stream keeps
    /// what it had.
    static func request(in properties: CMIOExtensionStreamProperties, stream: String) -> Request {
        var resolution: LemurCamConfig.Resolution?
        if let index = properties.activeFormatIndex {
            resolution = StreamFormatTable.resolution(atFormatIndex: index)
            if resolution == nil {
                Log.ext.error("Ignoring \(stream) format index \(index): no such format")
            }
        }
        var frameRate: LemurCamConfig.FrameRate?
        if let duration = properties.frameDuration {
            frameRate = StreamFormatTable.frameRate(forFrameDuration: duration)
            if frameRate == nil {
                Log.ext.error("Ignoring \(stream) frame duration \(duration.value)/\(duration.timescale): not offered")
            }
        }
        return Request(resolution: resolution, frameRate: frameRate)
    }
}

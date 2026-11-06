import CoreMedia
import CoreVideo

/// The extension's own placeholder, shown while the app sends no frames, drawn
/// at one of the camera's resolutions. `ExtensionDeviceRuntime` keeps one, for
/// the active format, and draws a new one when the format changes.
internal struct PlaceholderFrame: Sendable {
    /// The resolution the placeholder stands in for. Normally its size; see `standingIn(for:)`.
    let resolution: LemurCamConfig.Resolution
    let buffer: SendableRetainedReference<CVPixelBuffer>
    /// Made from `buffer`, so it describes the buffer the sample carries.
    let formatDescription: CMFormatDescription

    private static let text = "LemurCam is not running"
    private static let fontSize: CGFloat = 64

    /// Draws the placeholder at `resolution`; nil when drawing failed.
    static func render(at resolution: LemurCamConfig.Resolution) -> Self? {
        let height = Int(resolution.height)
        guard let rendered = PlaceholderRenderer.render(
            text: text,
            width: Int(resolution.width),
            height: height,
            fontSize: PlaceholderRenderer.fontSize(fontSize, forHeight: height)
        ) else { return nil }

        var description: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: rendered, formatDescriptionOut: &description
        )
        guard status == noErr, let description else { return nil }
        return Self(resolution: resolution, buffer: SendableRetainedReference(rendered), formatDescription: description)
    }

    /// This picture, kept for `resolution` after drawing one at that size failed,
    /// so the timer doesn't redraw on every tick. Its sample buffers still carry
    /// its own size.
    func standingIn(for resolution: LemurCamConfig.Resolution) -> Self {
        Self(resolution: resolution, buffer: buffer, formatDescription: formatDescription)
    }

    /// A sample buffer of the placeholder stamped `presentationTime`; nil on failure.
    func sampleBuffer(at presentationTime: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(
            duration: .invalid, presentationTimeStamp: presentationTime, decodeTimeStamp: .invalid
        )
        return buffer.withValue { imageBuffer -> CMSampleBuffer? in
            var sampleBuffer: CMSampleBuffer?
            let status = CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: imageBuffer, formatDescription: formatDescription,
                sampleTiming: &timing, sampleBufferOut: &sampleBuffer
            )
            return status == noErr ? sampleBuffer : nil
        }
    }
}

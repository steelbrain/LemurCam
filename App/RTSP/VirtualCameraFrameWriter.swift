import CoreMedia
import CoreVideo
import os

/// Converts decoded frames into CMIO-ready sample buffers and writes them into
/// the virtual-camera sink. Called from the jitter-buffer drain queue, not the
/// main actor; the cached format description is guarded by a lock.
internal final class VirtualCameraFrameWriter: Sendable {
    private struct FormatCache: Sendable {
        var description: CMVideoFormatDescription?
        /// A frame could not be turned into a sample buffer since the last one that
        /// could; the failure is logged once per such run, not for every frame.
        var failing = false
    }

    private let model: LemurCamModel
    private let formatCache = OSAllocatedUnfairLock<FormatCache>(initialState: FormatCache())

    init(model: LemurCamModel) {
        self.model = model
    }

    func write(_ pixelBuffer: CVPixelBuffer) {
        guard model.isStreaming,
              let sampleBuffer = sampleBuffer(for: pixelBuffer) else {
            return
        }
        model.sendSampleBuffer(sampleBuffer)
    }

    /// `pixelBuffer` as a sample buffer stamped with the host clock, or nil when one
    /// can't be made. Internal so tests can check it without a sink.
    func sampleBuffer(for pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        guard let formatDescription = formatDescription(for: pixelBuffer) else { return nil }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
            dataReady: true, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: formatDescription,
            sampleTiming: &timing, sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            reportFailure(status, making: "sample buffer")
            return nil
        }
        formatCache.withLock { $0.failing = false }
        return sampleBuffer
    }

    /// The cached format description when it still describes `pixelBuffer`, otherwise
    /// a new one made from it. A description covers more than the frame's size and
    /// pixel format: also the color attachments VideoToolbox sets from the stream
    /// (primaries, transfer function, YCbCr matrix, chroma location). Keyed on size
    /// and pixel format alone, the description cached for one camera was kept for the
    /// next one at that size with other color tags (BT.709 then BT.601, say), and every
    /// one of its frames failed to become a sample buffer (-12743, invalid media
    /// format) without a word: apps using the virtual camera kept showing the
    /// placeholder while LemurCam showed the camera connected.
    private func formatDescription(for pixelBuffer: CVPixelBuffer) -> CMVideoFormatDescription? {
        if let cached = formatCache.withLock({ $0.description }),
           CMVideoFormatDescriptionMatchesImageBuffer(cached, imageBuffer: pixelBuffer) {
            return cached
        }

        var created: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
            formatDescriptionOut: &created
        )
        guard status == noErr, let created else {
            reportFailure(status, making: "format description")
            return nil
        }
        formatCache.withLock { $0.description = created }
        return created
    }

    private func reportFailure(_ status: OSStatus, making what: String) {
        let firstInRun = formatCache.withLock { cache -> Bool in
            defer { cache.failing = true }
            return !cache.failing
        }
        guard firstInRun else { return }
        Log.ipc.error("Couldn't make a \(what) for a decoded frame (\(status)); dropping frames until one works")
    }
}

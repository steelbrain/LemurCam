import CoreMedia
import CoreVideo
import Foundation
import os

/// Converts decoded frames into CMIO-ready sample buffers and writes them into
/// the virtual-camera sink. Called from the jitter-buffer drain queue, not the
/// main actor; cached format-description state is guarded by `formatLock`.
internal final class VirtualCameraFrameWriter: Sendable {
    private struct FormatCache: Sendable {
        var description: CMVideoFormatDescription?
        var dims: FormatDimensions?
    }

    private struct FormatDimensions: Equatable, Sendable {
        let width: Int
        let height: Int
        let pixelFormat: OSType
    }

    private let model: LemurCamModel
    private let formatCache = OSAllocatedUnfairLock<FormatCache>(initialState: FormatCache())

    init(model: LemurCamModel) {
        self.model = model
    }

    func write(_ pixelBuffer: CVPixelBuffer) {
        guard model.isStreaming,
              let sampleBuffer = createSampleBuffer(from: pixelBuffer) else {
            return
        }
        model.sendSampleBuffer(sampleBuffer)
    }

    private func createSampleBuffer(from pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        let dims = FormatDimensions(
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer),
            pixelFormat: CVPixelBufferGetPixelFormatType(pixelBuffer)
        )
        guard let formatDescription = formatDescription(for: pixelBuffer, dims: dims) else {
            return nil
        }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
            dataReady: true, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: formatDescription,
            sampleTiming: &timing, sampleBufferOut: &sampleBuffer
        )
        return sampleBuffer
    }

    private func formatDescription(
        for pixelBuffer: CVPixelBuffer,
        dims: FormatDimensions
    ) -> CMVideoFormatDescription? {
        if let cached = formatCache.withLock({ cache -> CMVideoFormatDescription? in
            guard dims == cache.dims else { return nil }
            return cache.description
        }) {
            return cached
        }

        var createdDescription: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
            formatDescriptionOut: &createdDescription
        )
        let newDescription = createdDescription

        return formatCache.withLock {
            if let description = $0.description,
               dims == $0.dims {
                return description
            }

            $0.description = newDescription
            $0.dims = dims
            return newDescription
        }
    }
}

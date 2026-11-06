import CoreMedia
import CoreVideo
import os
import VideoToolbox

/// Scales the app's frames to one of the camera's resolutions for the source
/// stream. The app sends frames at the IP camera's own size; an app using the
/// virtual camera gets the size of the format it runs in. The picture keeps its
/// aspect ratio, with black bars filling the rest (`kVTScalingMode_Letterbox`).
///
/// One scaler serves one resolution: `ExtensionDeviceRuntime` makes one when the
/// first frame needs scaling to a new format, not per frame, and lends it to one
/// frame at a time, since a `VTPixelTransferSession` is not documented as safe
/// to use from two threads at once. Output buffers come from a pool, in the
/// pixel format every format advertises, IOSurface-backed so they cross to the
/// consuming apps without a copy.
internal final class SinkFrameScaler: Sendable {
    private struct Cache: Sendable {
        /// Describes the last output buffer; reused while it still matches.
        var formatDescription: CMFormatDescription?
        /// A frame failed since the last one that scaled; logged once per run.
        var failing = false
    }

    let resolution: LemurCamConfig.Resolution
    private let session: SendableRetainedReference<VTPixelTransferSession>
    private let pool: SendableRetainedReference<CVPixelBufferPool>
    private let cache = OSAllocatedUnfairLock(initialState: Cache())

    /// Nil when VideoToolbox or CoreVideo can't set up the session or the pool.
    init?(resolution: LemurCamConfig.Resolution) {
        var createdSession: VTPixelTransferSession?
        let sessionStatus = VTPixelTransferSessionCreate(
            allocator: kCFAllocatorDefault, pixelTransferSessionOut: &createdSession
        )
        guard sessionStatus == noErr, let createdSession else {
            Log.ext.error("Couldn't create a pixel transfer session for \(resolution.rawValue): \(sessionStatus)")
            return nil
        }
        VTSessionSetProperty(
            createdSession, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Letterbox
        )
        VTSessionSetProperty(createdSession, key: kVTPixelTransferPropertyKey_RealTime, value: kCFBooleanTrue)

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: StreamFormatTable.pixelFormat,
            kCVPixelBufferWidthKey as String: Int(resolution.width),
            kCVPixelBufferHeightKey as String: Int(resolution.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]
        var createdPool: CVPixelBufferPool?
        let poolStatus = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &createdPool)
        guard poolStatus == kCVReturnSuccess, let createdPool else {
            Log.ext.error("Couldn't create a \(resolution.rawValue) pixel buffer pool: \(poolStatus)")
            VTPixelTransferSessionInvalidate(createdSession)
            return nil
        }

        self.resolution = resolution
        session = SendableRetainedReference(createdSession)
        pool = SendableRetainedReference(createdPool)
    }

    deinit {
        session.withValue { VTPixelTransferSessionInvalidate($0) }
    }

    /// `source` scaled into a pool buffer, as a sample buffer stamped
    /// `presentationTime` whose format description matches it; nil when a step
    /// failed. The caller must not use this scaler from another thread meanwhile.
    func scale(_ source: CVPixelBuffer, presentationTime: CMTime) -> CMSampleBuffer? {
        var output: CVPixelBuffer?
        let poolStatus = pool.withValue { CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, $0, &output) }
        guard poolStatus == kCVReturnSuccess, let output else {
            return fail(poolStatus, making: "pool buffer")
        }
        let transferStatus = session.withValue { VTPixelTransferSessionTransferImage($0, from: source, to: output) }
        guard transferStatus == noErr else {
            return fail(transferStatus, making: "scaled frame")
        }
        guard let description = formatDescription(for: output) else { return nil }

        var timing = CMSampleTimingInfo(
            duration: .invalid, presentationTimeStamp: presentationTime, decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: output, formatDescription: description,
            sampleTiming: &timing, sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            return fail(status, making: "sample buffer")
        }
        cache.withLock { $0.failing = false }
        return sampleBuffer
    }

    /// The cached description while it still matches `buffer`, else a new one.
    /// The transfer sets the output's color attachments from the source, so a
    /// camera with other color tags needs another description at the same size.
    private func formatDescription(for buffer: CVPixelBuffer) -> CMFormatDescription? {
        if let cached = cache.withLock({ $0.formatDescription }),
           CMVideoFormatDescriptionMatchesImageBuffer(cached, imageBuffer: buffer) {
            return cached
        }
        var created: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &created
        )
        guard status == noErr, let created else {
            return fail(status, making: "format description")
        }
        cache.withLock { $0.formatDescription = created }
        return created
    }

    private func fail<Value>(_ status: OSStatus, making what: String) -> Value? {
        let firstInRun = cache.withLock { cache -> Bool in
            defer { cache.failing = true }
            return !cache.failing
        }
        if firstInRun {
            Log.ext.error("Couldn't make a \(what) at \(resolution.rawValue) (\(status)); sending frames unscaled")
        }
        return nil
    }
}

import CoreMedia
import CoreVideo
import os
import VideoToolbox

internal final class VideoDecoder {
    var onDecodedFrame: (@Sendable (CVPixelBuffer) -> Void)? {
        get { deliveryGate.onDecodedFrame }
        set { deliveryGate.onDecodedFrame = newValue }
    }

    private let deliveryGate = VideoDecoderDeliveryGate()
    /// One per error source: the output handler reports per-frame decode results on
    /// VideoToolbox's thread, and the submit call can fail synchronously on its own.
    private let outputErrors = DecodeErrorDeduper()
    private let submitErrors = DecodeErrorDeduper()
    private var session: VTDecompressionSession?
    /// The format the current session decodes; nil while there is no session.
    private var currentFormatDescription: CMVideoFormatDescription?

    var hasSession: Bool {
        session != nil
    }

    func updateFormatDescription(_ formatDescription: CMVideoFormatDescription, isKeyframe: Bool) {
        if let current = currentFormatDescription,
           CMFormatDescriptionEqual(current, otherFormatDescription: formatDescription) {
            return
        }
        // With no session (the last creation failed) retry only at a keyframe: a new
        // session can't decode the frames before one, so trying on each of them would
        // just repeat the failure at the frame rate.
        guard session != nil || isKeyframe else { return }

        tearDown()
        // Remember the format only once a session decodes it. A failed creation used
        // to be remembered too, so every later frame compared equal and was dropped.
        let created = createSession(formatDescription: formatDescription)
        currentFormatDescription = created ? formatDescription : nil
    }

    func decode(blockBuffer: CMBlockBuffer, formatDescription: CMVideoFormatDescription, isKeyframe: Bool) {
        guard let session else { return }

        guard let sampleBuffer = makeSampleBuffer(
            blockBuffer: blockBuffer,
            formatDescription: formatDescription
        ) else { return }

        applySyncAttachment(to: sampleBuffer, isKeyframe: isKeyframe)

        let decodeFlags: VTDecodeFrameFlags = [._EnableAsynchronousDecompression]
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: decodeFlags,
            infoFlagsOut: nil,
            outputHandler: { [deliveryGate, outputErrors] status, _, imageBuffer, _, _ in
                if outputErrors.shouldLog(status) {
                    Log.rtsp.error("Decode frame error: \(status)")
                }
                guard status == noErr, let pixelBuffer = imageBuffer else { return }
                deliveryGate.deliverIfActive(pixelBuffer)
            }
        )

        if submitErrors.shouldLog(decodeStatus) {
            Log.rtsp.error("VTDecompressionSessionDecodeFrame failed: \(decodeStatus)")
        }
    }

    /// Deliver a decoded frame unless the decoder has been torn down. Called from the
    /// VideoToolbox output handler on its own thread; a frame that arrives after
    /// `tearDown()` (during reconnect/format change) is dropped instead of leaking into
    /// the pipeline that has already moved on.
    func deliverIfActive(_ pixelBuffer: CVPixelBuffer) {
        deliveryGate.deliverIfActive(pixelBuffer)
    }

    func tearDown() {
        // Stop delivery first so frames drained by WaitForAsynchronousFrames below
        // (and any that race in afterwards) are suppressed rather than forwarded.
        deliveryGate.deactivate()
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
    }

    deinit {
        tearDown()
    }

    // MARK: - Private

    private func makeSampleBuffer(
        blockBuffer: CMBlockBuffer,
        formatDescription: CMVideoFormatDescription
    ) -> CMSampleBuffer? {
        var sampleSize = CMBlockBufferGetDataLength(blockBuffer)

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )

        guard status == noErr, let sampleBuffer else {
            Log.rtsp.error("Failed to create sample buffer: \(status)")
            return nil
        }
        return sampleBuffer
    }

    private func applySyncAttachment(to sampleBuffer: CMSampleBuffer, isKeyframe: Bool) {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true)
        if let attachments, CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            if !isKeyframe {
                CFDictionarySetValue(
                    dict,
                    Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                    Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
                )
            }
        }
    }

    private func createSession(formatDescription: CMVideoFormatDescription) -> Bool {
        // Request the decoder's native NV12 (4:2:0 biplanar, video range) output so
        // VideoToolbox skips the per-frame YUV->BGRA pixel transfer. The virtual
        // camera vends NV12 end to end, so no conversion is needed downstream.
        let outputAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]

        var callbackRecord = VTDecompressionOutputCallbackRecord()
        var newSession: VTDecompressionSession?

        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: outputAttributes as CFDictionary,
            outputCallback: &callbackRecord,
            decompressionSessionOut: &newSession
        )

        guard status == noErr, let newSession else {
            Log.rtsp.error("Failed to create decompression session: \(status)")
            return false
        }

        VTSessionSetProperty(newSession, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = newSession
        // A new session (format change) starts fresh, so its first error is logged
        // even if the old session's last frame failed the same way.
        outputErrors.reset()
        submitErrors.reset()
        // Re-enable delivery: `updateFormatDescription` tears the old session down
        // (clearing `isActive`) before creating this one on a mid-stream format change.
        deliveryGate.activate()
        Log.rtsp.info("Created decompression session")
        return true
    }
}

private final class VideoDecoderDeliveryGate: Sendable {
    private struct State: Sendable {
        var isActive = true
        var onDecodedFrame: (@Sendable (CVPixelBuffer) -> Void)?
    }

    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    var onDecodedFrame: (@Sendable (CVPixelBuffer) -> Void)? {
        get {
            state.withLock { $0.onDecodedFrame }
        }
        set {
            state.withLock {
                $0.onDecodedFrame = newValue
            }
        }
    }

    func activate() {
        state.withLock {
            $0.isActive = true
        }
    }

    func deactivate() {
        state.withLock {
            $0.isActive = false
        }
    }

    func deliverIfActive(_ pixelBuffer: CVPixelBuffer) {
        let callback = state.withLock {
            $0.isActive ? $0.onDecodedFrame : nil
        }
        callback?(pixelBuffer)
    }
}

/// Collapses a run of identical per-frame decode errors into one log line. After
/// packet loss every frame until the next keyframe can fail with the same status
/// (`kVTVideoDecoderBadDataErr` on an H.265 stream), which would otherwise log one
/// line per frame. An error is logged when it starts a run: the first error, or one
/// whose status differs from the error just before it. A successful decode ends
/// the run, so the same error recurring later is logged again. Called from
/// VideoToolbox's output thread and the decode loop, hence the lock.
internal final class DecodeErrorDeduper: Sendable {
    private let lastLoggedStatus = OSAllocatedUnfairLock<OSStatus?>(initialState: nil)

    /// Records one frame's decode status and returns whether to log it.
    func shouldLog(_ status: OSStatus) -> Bool {
        lastLoggedStatus.withLock { last in
            guard status != noErr else {
                last = nil
                return false
            }
            guard status != last else { return false }
            last = status
            return true
        }
    }

    func reset() {
        lastLoggedStatus.withLock {
            $0 = nil
        }
    }
}

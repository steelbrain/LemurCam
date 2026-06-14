import CoreMedia
import IPCamKit

internal struct ProcessedFrame {
    let blockBuffer: CMBlockBuffer
    let formatDescription: CMVideoFormatDescription
    let isKeyframe: Bool
}

internal final class NALProcessor {
    private let codec: VideoCodec
    private var sps: Data
    private var pps: Data
    private var vps: Data?
    private var formatDescription: CMVideoFormatDescription?
    private var receivedKeyframe = false

    init(codec: VideoCodec, sps: Data, pps: Data, vps: Data?) {
        self.codec = codec
        self.sps = sps
        self.pps = pps
        self.vps = vps

        // Parameter sets can be empty at session start and arrive in-band on the
        // first frames; defer building the format description to process(_:) in
        // that case rather than logging a spurious failure.
        guard !sps.isEmpty, !pps.isEmpty else {
            Log.rtsp.info("Awaiting in-band parameter sets")
            return
        }

        self.formatDescription = buildFormatDescription(sps: sps, pps: pps, vps: vps)
        if let desc = self.formatDescription {
            let dims = CMVideoFormatDescriptionGetDimensions(desc)
            Log.rtsp.info("Format description created: \(dims.width)x\(dims.height)")
        } else {
            Log.rtsp.error("Format description creation failed")
        }
    }

    func process(_ frame: PublicVideoFrame) -> ProcessedFrame? {
        // Update parameter sets if they changed
        if let newSPS = frame.sps, let newPPS = frame.pps {
            let changed = newSPS != sps || newPPS != pps || frame.vps != vps
            if changed {
                sps = newSPS
                pps = newPPS
                vps = frame.vps ?? vps
                formatDescription = buildFormatDescription(sps: sps, pps: pps, vps: vps)
                Log.rtsp.info("Parameter sets updated, rebuilt format description")
            }
        }

        guard let formatDescription else {
            Log.rtsp.warning("No format description available, dropping frame")
            return nil
        }

        // Wait for first keyframe before decoding
        if !receivedKeyframe {
            guard frame.isKeyframe else { return nil }
            receivedKeyframe = true
            Log.rtsp.info("Received first keyframe")
        }

        // Filter NALs — keep only VCL units (skip SEI, AUD, parameter sets)
        let filteredNALUs = frame.nalus.filter { shouldKeepNAL($0) }
        guard !filteredNALUs.isEmpty else { return nil }

        // Build CMBlockBuffer from filtered NALUs
        guard let blockBuffer = buildBlockBuffer(nalus: filteredNALUs) else { return nil }

        return ProcessedFrame(
            blockBuffer: blockBuffer,
            formatDescription: formatDescription,
            isKeyframe: frame.isKeyframe
        )
    }

    // MARK: - Private

    private func buildFormatDescription(
        sps: Data, pps: Data, vps: Data?
    ) -> CMVideoFormatDescription? {
        var desc: CMVideoFormatDescription?
        var status: OSStatus

        switch codec {
        case .h264:
            status = buildH264FormatDescription(sps: sps, pps: pps, out: &desc)
        case .h265:
            guard let result = buildHEVCFormatDescription(sps: sps, pps: pps, vps: vps, out: &desc) else {
                return nil
            }
            status = result
        }

        if status != noErr {
            Log.rtsp.error("Failed to create format description: \(status)")
            return nil
        }

        return desc
    }

    private func buildH264FormatDescription(
        sps: Data, pps: Data, out desc: inout CMVideoFormatDescription?
    ) -> OSStatus {
        guard !sps.isEmpty, !pps.isEmpty else {
            Log.rtsp.error("Empty parameter set: sps=\(sps.count) pps=\(pps.count)")
            return OSStatus(kCMFormatDescriptionError_InvalidParameter)
        }
        var sizes = [sps.count, pps.count]
        return sps.withUnsafeBytes { spsPtr in
            pps.withUnsafeBytes { ppsPtr in
                guard let spsBase = spsPtr.baseAddress,
                      let ppsBase = ppsPtr.baseAddress else {
                    return OSStatus(kCMFormatDescriptionError_InvalidParameter)
                }
                var pointers: [UnsafePointer<UInt8>] = [
                    spsBase.assumingMemoryBound(to: UInt8.self),
                    ppsBase.assumingMemoryBound(to: UInt8.self)
                ]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: &pointers,
                    parameterSetSizes: &sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &desc
                )
            }
        }
    }

    private func buildHEVCFormatDescription(
        sps: Data, pps: Data, vps: Data?, out desc: inout CMVideoFormatDescription?
    ) -> OSStatus? {
        guard let vps, !vps.isEmpty else {
            Log.rtsp.error("H.265 requires non-empty VPS")
            return nil
        }
        guard !sps.isEmpty, !pps.isEmpty else {
            Log.rtsp.error("Empty parameter set: sps=\(sps.count) pps=\(pps.count)")
            return nil
        }

        var sizes = [vps.count, sps.count, pps.count]
        return vps.withUnsafeBytes { vpsPtr in
            sps.withUnsafeBytes { spsPtr in
                pps.withUnsafeBytes { ppsPtr in
                    guard let vpsBase = vpsPtr.baseAddress,
                          let spsBase = spsPtr.baseAddress,
                          let ppsBase = ppsPtr.baseAddress else {
                        return OSStatus(kCMFormatDescriptionError_InvalidParameter)
                    }
                    var pointers: [UnsafePointer<UInt8>] = [
                        vpsBase.assumingMemoryBound(to: UInt8.self),
                        spsBase.assumingMemoryBound(to: UInt8.self),
                        ppsBase.assumingMemoryBound(to: UInt8.self)
                    ]
                    return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: 3,
                        parameterSetPointers: &pointers,
                        parameterSetSizes: &sizes,
                        nalUnitHeaderLength: 4,
                        extensions: nil,
                        formatDescriptionOut: &desc
                    )
                }
            }
        }
    }

    func shouldKeepNAL(_ nalData: Data) -> Bool {
        // NAL data is raw bytes (no length prefix) — first byte is the NAL header
        guard !nalData.isEmpty else { return false }

        let firstByte = nalData[nalData.startIndex]

        switch codec {
        case .h264:
            let nalType = firstByte & 0x1F
            // Drop SEI (6), SPS (7), PPS (8), AUD (9) — parameter sets are in the format description
            return !(nalType >= 6 && nalType <= 9)

        case .h265:
            let nalType = (firstByte >> 1) & 0x3F
            // Drop VPS (32), SPS (33), PPS (34), AUD (35), EOS (36), EOB (37), FD (38), SEI (39-40)
            return !(nalType >= 32 && nalType <= 40)
        }
    }

    func buildBlockBuffer(nalus: [Data]) -> CMBlockBuffer? {
        // AVCC layout per NAL: [4-byte big-endian length][NAL bytes].
        var totalLength = 0
        for nalu in nalus { totalLength += 4 + nalu.count }
        guard totalLength > 0 else { return nil }

        // One allocation, one copy: write the AVCC bytes straight into the block's
        // backing memory. CMBlockBuffer takes ownership and frees it via the custom
        // block source on dispose, so there is no intermediate Data (and its
        // reallocations) and no second CMBlockBufferReplaceDataBytes copy.
        let memory = UnsafeMutableRawPointer.allocate(byteCount: totalLength, alignment: 1)
        Self.writeAVCC(nalus: nalus, into: memory)

        var source = CMBlockBufferCustomBlockSource(
            version: kCMBlockBufferCustomBlockSourceVersion,
            AllocateBlock: nil,
            FreeBlock: { _, doomedMemoryBlock, _ in doomedMemoryBlock.deallocate() },
            refCon: nil
        )
        var blockBuffer: CMBlockBuffer?
        let status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: memory,
            blockLength: totalLength,
            blockAllocator: nil,
            customBlockSource: &source,
            offsetToData: 0,
            dataLength: totalLength,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        // On success CMBlockBuffer owns `memory` (freed via FreeBlock); on failure it
        // was never adopted, so release it here to avoid a leak.
        guard status == kCMBlockBufferNoErr, let blockBuffer else {
            memory.deallocate()
            Log.rtsp.error("Failed to create block buffer: \(status)")
            return nil
        }
        return blockBuffer
    }

    /// Write the AVCC representation of `nalus` into `memory`, which must be at least
    /// `sum(4 + nalu.count)` bytes. Each NAL is prefixed with its 4-byte big-endian
    /// length and copied by its own slice bounds.
    private static func writeAVCC(nalus: [Data], into memory: UnsafeMutableRawPointer) {
        let base = memory.assumingMemoryBound(to: UInt8.self)
        var offset = 0
        for nalu in nalus {
            let count = nalu.count
            let length = UInt32(count)
            base[offset] = UInt8(truncatingIfNeeded: length >> 24)
            base[offset + 1] = UInt8(truncatingIfNeeded: length >> 16)
            base[offset + 2] = UInt8(truncatingIfNeeded: length >> 8)
            base[offset + 3] = UInt8(truncatingIfNeeded: length)
            offset += 4
            if count > 0 {
                nalu.copyBytes(to: base.advanced(by: offset), count: count)
                offset += count
            }
        }
    }
}

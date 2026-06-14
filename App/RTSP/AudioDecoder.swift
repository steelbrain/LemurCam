import AudioToolbox
import AVFoundation
import Foundation
import IPCamKit

/// Decodes a camera's audio frames to 48 kHz Float32 interleaved stereo PCM for the
/// virtual-microphone ring. Created per stream (like `VideoDecoder`) from the
/// negotiated `AudioStream`. Handles G.711 (µ-law/A-law), L16, and AAC. Unsupported
/// codecs are logged once and produce no audio.
internal final class AudioDecoder {
    /// Decoded 48 kHz Float32 interleaved stereo PCM. The pointer is valid only for
    /// the duration of the call. Invoked on the frame-consuming task, not the main actor.
    var onPCM: (@Sendable (UnsafePointer<Float>, Int) -> Void)?

    let sourceRate: Double
    let sourceChannels: Int
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?
    /// Grow-only PCM buffers reused across `resampleAndEmit` calls so the steady
    /// state allocates nothing. Safe to reuse without locking: decode runs only on
    /// the single `frames()` consumer loop and each buffer is fully consumed (via the
    /// synchronous `onPCM`) before the next call. See `reusableBuffer(_:format:frames:)`.
    private var reusableInputBuffer: AVAudioPCMBuffer?
    private var reusableOutputBuffer: AVAudioPCMBuffer?
    /// Grow-only scratch the AAC decoder writes each access unit into, reused across
    /// calls (sized once for the worst-case 2048-frame HE-AAC output). Single-threaded
    /// like the reusable PCM buffers above.
    private var aacPCMScratch: [Float] = []
    var aacConverter: AudioConverterRef?
    /// Reused across AAC frames: holds the single in-flight access unit the converter
    /// input proc vends. Allocated lazily on the first AAC frame, freed in `tearDown`.
    private var aacPacket: AACPacket?
    private var loggedUnsupported = false

    static let outputSampleRate: Double = 48_000
    static let outputChannels: AVAudioChannelCount = 2

    /// Designated initializer. The `stream:` convenience init derives the source
    /// rate/channels from the negotiated `AudioStream`; tests use this directly
    /// because `AudioStream`'s memberwise init is internal to IPCamKit.
    init(sourceRate: Double, sourceChannels: Int) {
        self.sourceRate = sourceRate
        self.sourceChannels = sourceChannels
        setUpConverter()
    }

    convenience init(stream: AudioStream) {
        let sdpRate = stream.sampleRate > 0 ? Double(stream.sampleRate) : 8000
        // G.711 is always mono; otherwise trust the advertised channel count.
        let sdpChannels: Int
        switch stream.codec {
        case .pcmu, .pcma:
            sdpChannels = 1
        default:
            sdpChannels = max(1, Int(stream.channels ?? 1))
        }
        if case .aac = stream.codec {
            // AAC geometry is authoritative in the in-band AudioSpecificConfig, which
            // can disagree with the SDP. Source it from the ASC so the AAC decoder's
            // input format, its output format, the scratch sizing, and the resampler
            // all agree — otherwise a misreporting camera gets remapped or silent audio.
            let geometry = Self.aacSourceGeometry(
                asc: stream.extraData ?? Data(), sdpRate: sdpRate, sdpChannels: sdpChannels
            )
            self.init(sourceRate: geometry.rate, sourceChannels: geometry.channels)
            setUpAAC(stream)
        } else {
            self.init(sourceRate: sdpRate, sourceChannels: sdpChannels)
        }
    }

    deinit {
        tearDown()
    }

    func tearDown() {
        converter?.reset()
        converter = nil
        reusableInputBuffer = nil
        reusableOutputBuffer = nil
        aacPCMScratch = []
        if let aacConverter { AudioConverterDispose(aacConverter) }
        aacConverter = nil
        aacPacket?.deallocate()
        aacPacket = nil
    }

    func decode(_ frame: PublicAudioFrame) {
        let interleaved: [Float]
        switch frame.codec {
        case .pcmu:
            interleaved = Self.decodeG711(frame.data, table: Self.muLawTable)
        case .pcma:
            interleaved = Self.decodeG711(frame.data, table: Self.aLawTable)
        case .l16:
            interleaved = Self.decodeL16(frame.data)
        case .aac:
            decodeAAC(frame.data)
            return
        case .g722, .g723, .other:
            logUnsupportedOnce(frame.codec)
            return
        }
        resampleAndEmit(interleaved[...])
    }

    // MARK: - Resample

    private func setUpConverter() {
        guard let inFmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sourceRate,
            channels: AVAudioChannelCount(sourceChannels), interleaved: true
        ), let outFmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Self.outputSampleRate,
            channels: Self.outputChannels, interleaved: true
        ) else {
            Log.rtsp.error("AudioDecoder: could not build audio formats")
            return
        }
        inputFormat = inFmt
        outputFormat = outFmt
        let conv = AVAudioConverter(from: inFmt, to: outFmt)
        // Duplicate mono into both output channels; pass stereo through unchanged.
        if sourceChannels == 1 {
            conv?.channelMap = [0, 0]
        }
        converter = conv
    }

    /// Return a reusable PCM buffer for `format` with capacity at least `frames`,
    /// reallocating (and caching) only when the cached buffer is missing or too small.
    private func reusableBuffer(
        _ cache: inout AVAudioPCMBuffer?, format: AVAudioFormat, frames: AVAudioFrameCount
    ) -> AVAudioPCMBuffer? {
        if let buf = cache, buf.frameCapacity >= frames { return buf }
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        cache = buf
        return buf
    }

    func resampleAndEmit(_ samples: ArraySlice<Float>) {
        guard !samples.isEmpty, let converter, let inputFormat, let outputFormat else { return }
        let inFrames = samples.count / sourceChannels
        guard inFrames > 0,
              let inBuf = reusableBuffer(
                  &reusableInputBuffer, format: inputFormat, frames: AVAudioFrameCount(inFrames)
              ), let inChannel = inBuf.floatChannelData else { return }
        inBuf.frameLength = AVAudioFrameCount(inFrames)
        samples.withUnsafeBufferPointer { src in
            if let base = src.baseAddress { inChannel[0].update(from: base, count: src.count) }
        }

        let outCap = AVAudioFrameCount(Double(inFrames) * Self.outputSampleRate / sourceRate) + 2048
        guard let outBuf = reusableBuffer(
            &reusableOutputBuffer, format: outputFormat, frames: outCap
        ) else { return }
        outBuf.frameLength = 0
        let input = SingleBufferAudioInput(buffer: inBuf)
        var error: NSError?
        let status = converter.convert(to: outBuf, error: &error) { _, inStatus in
            input.next(status: inStatus)
        }
        if status == .error {
            if let error { Log.rtsp.error("AudioDecoder: resample failed: \(error.localizedDescription)") }
            return
        }
        let outFrames = Int(outBuf.frameLength)
        guard outFrames > 0, let out = outBuf.floatChannelData?[0] else { return }
        onPCM?(out, outFrames)
    }

    private func logUnsupportedOnce(_ codec: PublicAudioCodec) {
        guard !loggedUnsupported else { return }
        loggedUnsupported = true
        Log.rtsp.warning("AudioDecoder: unsupported codec \(String(describing: codec)); no microphone audio")
    }
}

// MARK: - G.711 / L16

// Not `private`: the pure decode helpers below are unit-tested via `@testable`.
internal extension AudioDecoder {
    static let muLawTable: [Int16] = (0..<256).map { muLawToLinear(UInt8($0)) }
    static let aLawTable: [Int16] = (0..<256).map { aLawToLinear(UInt8($0)) }

    /// Decode G.711 bytes to mono Float32 in [-1, 1) via a precomputed table.
    static func decodeG711(_ data: Data, table: [Int16]) -> [Float] {
        guard !data.isEmpty else { return [] }
        var out = [Float](repeating: 0, count: data.count)
        for (index, byte) in data.enumerated() {
            out[index] = Float(table[Int(byte)]) / 32_768
        }
        return out
    }

    /// Decode L16 (16-bit big-endian PCM) to Float32 in [-1, 1), interleaving preserved.
    static func decodeL16(_ data: Data) -> [Float] {
        let count = data.count / 2
        guard count > 0 else { return [] }
        var out = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for index in 0..<count {
                let sample = Int16(bitPattern: (UInt16(bytes[index * 2]) << 8) | UInt16(bytes[index * 2 + 1]))
                out[index] = Float(sample) / 32_768
            }
        }
        return out
    }

    static func muLawToLinear(_ uVal: UInt8) -> Int16 {
        let bias = 0x84
        let inverted = ~uVal
        var sample = ((Int(inverted & 0x0F) << 3) + bias) << ((Int(inverted) & 0x70) >> 4)
        sample -= bias
        return (inverted & 0x80) != 0 ? Int16(-sample) : Int16(sample)
    }

    static func aLawToLinear(_ aVal: UInt8) -> Int16 {
        let xored = Int(aVal ^ 0x55)
        var magnitude = (xored & 0x0F) << 4
        let segment = (xored & 0x70) >> 4
        switch segment {
        case 0: magnitude += 8
        case 1: magnitude += 0x108
        default:
            magnitude += 0x108
            magnitude <<= (segment - 1)
        }
        return (xored & 0x80) != 0 ? Int16(magnitude) : Int16(-magnitude)
    }

    /// Wrap a bare AudioSpecificConfig in an MPEG-4 ES descriptor (ESDS) blob — the
    /// form CoreAudio's AAC decoder requires as its decompression magic cookie.
    /// Mirrors FFmpeg's `ffat_get_magic_cookie`: ES (0x03) → DecoderConfig (0x04) →
    /// DecoderSpecificInfo (0x05) == the ASC, each with a 4-byte expanded size field.
    static func aacMagicCookie(from asc: Data) -> Data {
        var out = Data()
        func putDescriptor(_ tag: UInt8, _ size: Int) {
            out.append(tag)
            out.append(UInt8((size >> 21) & 0x7F) | 0x80)
            out.append(UInt8((size >> 14) & 0x7F) | 0x80)
            out.append(UInt8((size >> 7) & 0x7F) | 0x80)
            out.append(UInt8(size & 0x7F))
        }
        putDescriptor(0x03, 3 + (5 + 13) + (5 + asc.count)) // ES_Descriptor
        out.append(contentsOf: [0x00, 0x00, 0x00])          // ES_ID (2) + flags (1)
        putDescriptor(0x04, 13 + (5 + asc.count))           // DecoderConfigDescriptor
        out.append(0x40)                                    // objectType: Audio ISO/IEC 14496-3
        out.append(0x15)                                    // streamType = audio, upstream 0
        out.append(contentsOf: [0x00, 0x00, 0x00])          // bufferSizeDB
        out.append(contentsOf: [0x00, 0x00, 0x00, 0x00])    // maxBitrate
        out.append(contentsOf: [0x00, 0x00, 0x00, 0x00])    // avgBitrate
        putDescriptor(0x05, asc.count)                      // DecoderSpecificInfo == ASC
        out.append(asc)
        return out
    }

    /// Input format for the AAC decoder, derived from the ESDS cookie via the
    /// FormatInfo property so the sample rate / channels / object type come from the
    /// authoritative AudioSpecificConfig rather than being hand-guessed. Returns nil if
    /// the cookie can't be parsed, so setup fails loudly instead of feeding an all-zero
    /// format into `AudioConverterNew` and only erroring per-access-unit at decode time.
    static func aacInputASBD(cookie: Data) -> AudioStreamBasicDescription? {
        var asbd = AudioStreamBasicDescription()
        asbd.mFormatID = kAudioFormatMPEG4AAC
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = cookie.withUnsafeBytes { raw in
            AudioFormatGetProperty(
                kAudioFormatProperty_FormatInfo, UInt32(raw.count), raw.baseAddress, &size, &asbd
            )
        }
        guard status == noErr, asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0 else { return nil }
        return asbd
    }

    /// The source geometry (sample rate, channel count) the decoder should feed its
    /// resampler for an AAC stream. The authoritative values live in the in-band
    /// AudioSpecificConfig, which can disagree with the SDP-advertised rate/channels
    /// (notably HE-AAC, where the ASC's base rate differs from the advertised one). Read
    /// them from the ASC so input/output formats and buffer sizing all agree; fall back
    /// to the SDP only when the ASC is absent or unparseable.
    static func aacSourceGeometry(
        asc: Data, sdpRate: Double, sdpChannels: Int
    ) -> (rate: Double, channels: Int) {
        guard !asc.isEmpty, let asbd = aacInputASBD(cookie: aacMagicCookie(from: asc)) else {
            return (sdpRate, sdpChannels)
        }
        return (asbd.mSampleRate, max(1, Int(asbd.mChannelsPerFrame)))
    }

    /// Canonical interleaved Float32 PCM output format the decoder targets.
    static func pcmOutputASBD(rate: Double, channels: Int) -> AudioStreamBasicDescription {
        var asbd = AudioStreamBasicDescription()
        asbd.mSampleRate = rate
        asbd.mFormatID = kAudioFormatLinearPCM
        asbd.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        asbd.mFramesPerPacket = 1
        asbd.mChannelsPerFrame = UInt32(channels)
        asbd.mBitsPerChannel = 32
        asbd.mBytesPerFrame = UInt32(MemoryLayout<Float>.size * channels)
        asbd.mBytesPerPacket = asbd.mBytesPerFrame
        return asbd
    }
}

// MARK: - AAC

private extension AudioDecoder {
    func setUpAAC(_ stream: AudioStream) {
        guard let asc = stream.extraData, !asc.isEmpty else {
            Log.rtsp.error("AudioDecoder: AAC stream has no AudioSpecificConfig; no microphone audio")
            return
        }
        // CoreAudio's AAC decoder needs the AudioSpecificConfig ESDS-wrapped as its
        // magic cookie; a bare ASC makes AudioCodecInitialize fail. Derive the input
        // format from that cookie (the authoritative ASC) like FFmpeg's decoder does.
        let cookie = Self.aacMagicCookie(from: asc)
        guard var inASBD = Self.aacInputASBD(cookie: cookie) else {
            Log.rtsp.error("AudioDecoder: could not parse AAC AudioSpecificConfig; no microphone audio")
            return
        }
        var outASBD = Self.pcmOutputASBD(rate: sourceRate, channels: sourceChannels)

        var conv: AudioConverterRef?
        guard AudioConverterNew(&inASBD, &outASBD, &conv) == noErr, let conv else {
            Log.rtsp.error("AudioDecoder: could not create AAC decoder")
            return
        }
        cookie.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                AudioConverterSetProperty(
                    conv, kAudioConverterDecompressionMagicCookie, UInt32(raw.count), base
                )
            }
        }
        aacConverter = conv
    }

    func decodeAAC(_ data: Data) {
        guard let aacConverter, !data.isEmpty else { return }
        // Reuse one packet across frames; the converter consumes it synchronously
        // within AudioConverterFillComplexBuffer below, so it's free to refill next call.
        let packet = aacPacket ?? AACPacket(channels: sourceChannels)
        aacPacket = packet
        packet.load(data)

        let channels = sourceChannels
        // Capacity for the largest common AAC output per access unit: AAC-LC is 1024,
        // but HE-AAC (SBR) doubles to 2048. The decoder reports the true count back.
        var frameCount: UInt32 = 2048
        let capacity = Int(frameCount) * channels
        if aacPCMScratch.count < capacity {
            aacPCMScratch = [Float](repeating: 0, count: capacity)
        }
        let status = aacPCMScratch.withUnsafeMutableBytes { rawOut -> OSStatus in
            var abl = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(channels),
                    mDataByteSize: UInt32(rawOut.count),
                    mData: rawOut.baseAddress
                )
            )
            return AudioConverterFillComplexBuffer(
                aacConverter, Self.aacInputProc,
                Unmanaged.passUnretained(packet).toOpaque(), &frameCount, &abl, nil
            )
        }
        guard frameCount > 0 else {
            if status != noErr, status != Self.aacInputEnded {
                Log.rtsp.error("AudioDecoder: AAC decode failed (\(status))")
            }
            return
        }
        resampleAndEmit(aacPCMScratch[0 ..< Int(frameCount) * channels])
    }

    /// Returned by the AAC input proc once the single pending access unit has been
    /// vended. Signalling "no more input" with a non-zero status (rather than noErr +
    /// zero packets) makes `AudioConverterFillComplexBuffer` return the frames decoded
    /// so far WITHOUT latching the shared converter into terminal end-of-stream. With
    /// the noErr-EOS form, the converter's second call per cycle (it asks for up to
    /// 2048 frames but one AAC-LC packet yields 1024) permanently ends the stream, so
    /// only the first access unit ever decodes — one frame, then silence.
    static let aacInputEnded: OSStatus = 0x6C_6D_45_6F // 'lmEo'

    /// Non-capturing C callback: hands the converter the single pending AAC access
    /// unit once, then reports end-of-input. Context is the `AACPacket` via userData.
    static let aacInputProc: AudioConverterComplexInputDataProc = { _, ioPackets, ioData, outDesc, ctx in
        guard let ctx else {
            ioPackets.pointee = 0
            return AudioDecoder.aacInputEnded
        }
        let packet = Unmanaged<AACPacket>.fromOpaque(ctx).takeUnretainedValue()
        if packet.consumed {
            ioPackets.pointee = 0
            return AudioDecoder.aacInputEnded
        }
        packet.consumed = true
        ioPackets.pointee = 1
        ioData.pointee.mNumberBuffers = 1
        ioData.pointee.mBuffers.mNumberChannels = packet.channels
        ioData.pointee.mBuffers.mDataByteSize = UInt32(packet.byteCount)
        ioData.pointee.mBuffers.mData = packet.pointer
        // AAC is externally framed, so the converter always passes a non-nil slot here;
        // the optional-chaining no-op on nil is a safe belt-and-suspenders.
        outDesc?.pointee = packet.packetDescription
        return noErr
    }
}

/// Holds one AAC access unit plus its packet description in stable heap storage so
/// the `AudioConverter` input callback can vend valid pointers. Reused across frames
/// via `load(_:)` with a grow-only backing buffer: the converter consumes the packet
/// synchronously inside `AudioConverterFillComplexBuffer`, so it is safe to refill.
private final class AACPacket {
    private(set) var pointer: UnsafeMutableRawPointer
    private(set) var byteCount = 0
    private var capacity: Int
    let channels: UInt32
    var consumed = false
    let packetDescription: UnsafeMutablePointer<AudioStreamPacketDescription>

    init(channels: Int) {
        self.channels = UInt32(channels)
        capacity = 1
        pointer = .allocate(byteCount: capacity, alignment: 1)
        packetDescription = .allocate(capacity: 1)
        packetDescription.initialize(to: AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: 0
        ))
    }

    /// Copy a new access unit in (growing the buffer if needed) and arm it for one
    /// fresh `AudioConverterFillComplexBuffer` cycle.
    func load(_ data: Data) {
        if data.count > capacity {
            pointer.deallocate()
            capacity = data.count
            pointer = .allocate(byteCount: max(1, capacity), alignment: 1)
        }
        byteCount = data.count
        data.copyBytes(to: pointer.assumingMemoryBound(to: UInt8.self), count: data.count)
        packetDescription.pointee.mDataByteSize = UInt32(data.count)
        consumed = false
    }

    func deallocate() {
        pointer.deallocate()
        packetDescription.deinitialize(count: 1)
        packetDescription.deallocate()
    }
}

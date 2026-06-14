import Foundation
@testable import LemurCam
import os
import XCTest

/// Verifies the deterministic audio-decode math that feeds the virtual microphone:
/// G.711 µ-law/A-law (against an independent ITU/Sun reference for every byte) and
/// L16 big-endian PCM. The AAC path needs a live decoder and is covered on-device.
internal final class AudioDecoderTests: XCTestCase {

    // MARK: - Reference G.711 (Sun/ITU reference implementation)

    private func referenceMuLaw(_ uVal: UInt8) -> Int16 {
        let inverted = ~uVal
        var sample = ((Int(inverted) & 0x0F) << 3) + 0x84
        sample <<= (Int(inverted) & 0x70) >> 4
        return (inverted & 0x80) != 0 ? Int16(0x84 - sample) : Int16(sample - 0x84)
    }

    private func referenceALaw(_ aVal: UInt8) -> Int16 {
        let xored = Int(aVal ^ 0x55)
        var sample = (xored & 0x0F) << 4
        let segment = (xored & 0x70) >> 4
        switch segment {
        case 0: sample += 8
        case 1: sample += 0x108
        default:
            sample += 0x108
            sample <<= (segment - 1)
        }
        return (xored & 0x80) != 0 ? Int16(sample) : Int16(-sample)
    }

    // MARK: - G.711 decode

    func testMuLawMatchesReferenceForAllBytes() {
        for byte in 0...255 {
            XCTAssertEqual(
                AudioDecoder.muLawToLinear(UInt8(byte)), referenceMuLaw(UInt8(byte)),
                "µ-law mismatch at byte \(byte)"
            )
        }
    }

    func testALawMatchesReferenceForAllBytes() {
        for byte in 0...255 {
            XCTAssertEqual(
                AudioDecoder.aLawToLinear(UInt8(byte)), referenceALaw(UInt8(byte)),
                "A-law mismatch at byte \(byte)"
            )
        }
    }

    func testMuLawKnownVectors() {
        XCTAssertEqual(AudioDecoder.muLawToLinear(0xFF), 0)
        XCTAssertEqual(AudioDecoder.muLawToLinear(0x7F), 0)
        XCTAssertEqual(AudioDecoder.muLawToLinear(0x00), -32_124)
        XCTAssertEqual(AudioDecoder.muLawToLinear(0x80), 32_124)
    }

    func testALawKnownVectors() {
        XCTAssertEqual(AudioDecoder.aLawToLinear(0x00), -5504)
        XCTAssertEqual(AudioDecoder.aLawToLinear(0xFF), 848)
        XCTAssertEqual(AudioDecoder.aLawToLinear(0x80), 5504)
        XCTAssertEqual(AudioDecoder.aLawToLinear(0x7F), -848)
    }

    func testDecodeG711NormalizesViaTable() {
        let table = [Int16](repeating: 16_384, count: 256)
        let out = AudioDecoder.decodeG711(Data([0, 128, 255]), table: table)
        XCTAssertEqual(out, [0.5, 0.5, 0.5])
    }

    func testDecodeG711Empty() {
        let table = [Int16](repeating: 0, count: 256)
        XCTAssertTrue(AudioDecoder.decodeG711(Data(), table: table).isEmpty)
    }

    // MARK: - G.711 lookup tables (decode path wiring)

    /// `decode(.pcmu/.pcma)` runs bytes through the precomputed `muLawTable`/
    /// `aLawTable`, not the per-byte functions. Verify the *shipped* tables match
    /// the independent ITU/Sun reference for all 256 bytes — comparing against the
    /// reference (not the functions the tables are built from) so a table wired to
    /// the wrong law, a mis-indexed map, or a regressed formula all surface here.
    func testLookupTablesMatchReferenceForAllBytes() {
        for byte in 0...255 {
            XCTAssertEqual(AudioDecoder.muLawTable[byte], referenceMuLaw(UInt8(byte)),
                           "µ-law table mismatch at byte \(byte)")
            XCTAssertEqual(AudioDecoder.aLawTable[byte], referenceALaw(UInt8(byte)),
                           "A-law table mismatch at byte \(byte)")
        }
    }

    /// End-to-end through the *real* µ-law table: known bytes normalize to [-1, 1)
    /// by dividing the decoded 16-bit sample by 32768.
    func testDecodeG711UsesRealMuLawTable() {
        let out = AudioDecoder.decodeG711(Data([0xFF, 0x00, 0x80]), table: AudioDecoder.muLawTable)
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(out[0], 0.0, accuracy: 1e-6)                  // 0xFF -> 0
        XCTAssertEqual(out[1], -32_124.0 / 32_768.0, accuracy: 1e-6) // 0x00 -> -32124
        XCTAssertEqual(out[2], 32_124.0 / 32_768.0, accuracy: 1e-6)  // 0x80 -> +32124
    }

    // MARK: - L16 decode

    func testDecodeL16BigEndian() {
        // 0x7FFF (+full), 0x8000 (−full), 0x0000 (silence).
        let out = AudioDecoder.decodeL16(Data([0x7F, 0xFF, 0x80, 0x00, 0x00, 0x00]))
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(out[0], 32_767.0 / 32_768.0, accuracy: 1e-6)
        XCTAssertEqual(out[1], -1.0, accuracy: 1e-6)
        XCTAssertEqual(out[2], 0.0, accuracy: 1e-6)
    }

    func testDecodeL16DropsTrailingOddByte() {
        let out = AudioDecoder.decodeL16(Data([0x00, 0x01, 0x00, 0x02, 0xFF]))
        XCTAssertEqual(out.count, 2)
    }

    func testDecodeL16Empty() {
        XCTAssertTrue(AudioDecoder.decodeL16(Data()).isEmpty)
    }

    // MARK: - Resample (reused buffers)

    /// Exercise the live `AVAudioConverter` resample path across allocate → grow →
    /// reuse calls (the reusable input/output `AVAudioPCMBuffer`s). The converter is
    /// stateful, so successive outputs aren't bit-equal; instead assert the invariant
    /// that survives buffer reuse: mono input is duplicated to both output channels
    /// (`channelMap [0, 0]`), so every interleaved L/R pair matches. Stale data leaking
    /// from a prior (larger) call would break that pairing.
    func testResampleProducesDuplicatedStereoAcrossReusedBuffers() {
        let decoder = AudioDecoder(sourceRate: 8000, sourceChannels: 1)
        let recorder = PCMRecorder()
        decoder.onPCM = { ptr, frames in
            recorder.record(ptr, frames: frames)
        }
        // 160 allocates, 320 grows both buffers, 160 reuses without growing.
        for count in [160, 320, 160] {
            let input = (0..<count).map { Float(sin(Double($0) * 0.05)) }
            decoder.resampleAndEmit(input[...])
            let lastOut = recorder.snapshot()
            XCTAssertFalse(lastOut.isEmpty, "no PCM emitted for \(count) input frames")
            for frame in stride(from: 0, to: lastOut.count, by: 2) {
                XCTAssertEqual(lastOut[frame], lastOut[frame + 1], accuracy: 1e-6, "L/R mismatch at \(frame)")
            }
        }
    }

    // MARK: - AAC magic cookie (ESDS)

    /// The decompression magic cookie must be the ASC wrapped in an ES descriptor
    /// tree (a bare ASC makes AudioCodecInitialize fail). Lock the exact byte layout
    /// for the canonical 48 kHz-stereo AAC-LC config (ASC 0x11 0x90).
    func testAACMagicCookieWrapsASCInESDS() {
        let cookie = AudioDecoder.aacMagicCookie(from: Data([0x11, 0x90]))
        let expected: [UInt8] = [
            0x03, 0x80, 0x80, 0x80, 0x1C, // ES_Descriptor, payload size 28
            0x00, 0x00, 0x00,             // ES_ID (2) + flags (1)
            0x04, 0x80, 0x80, 0x80, 0x14, // DecoderConfigDescriptor, payload size 20
            0x40, 0x15,                   // objectType (AAC) + streamType (audio)
            0x00, 0x00, 0x00,             // bufferSizeDB
            0x00, 0x00, 0x00, 0x00,       // maxBitrate
            0x00, 0x00, 0x00, 0x00,       // avgBitrate
            0x05, 0x80, 0x80, 0x80, 0x02, // DecoderSpecificInfo, payload size 2
            0x11, 0x90                    // the ASC itself
        ]
        XCTAssertEqual([UInt8](cookie), expected)
    }

    /// An ASC larger than 127 bytes (e.g. HE-AAC configs) must still encode correct
    /// descriptor sizes via the 4-byte expanded length form, with the ASC appended
    /// verbatim at the tail.
    func testAACMagicCookieEncodesLargeASCSizes() {
        let asc = Data(repeating: 0xAB, count: 130)
        let cookie = AudioDecoder.aacMagicCookie(from: asc)
        // Fixed overhead is 31 bytes (5+3 ES, 5+13 DecoderConfig, 5 DSI header).
        XCTAssertEqual(cookie.count, 31 + 130)
        // ES_Descriptor size = 3 + 18 + (5 + 130) = 156 -> 0x80 0x80 0x81 0x1C.
        XCTAssertEqual([UInt8](cookie.prefix(5)), [0x03, 0x80, 0x80, 0x81, 0x1C])
        // DecoderSpecificInfo header sits 135 bytes before the end; size 130 -> 0x81 0x02.
        XCTAssertEqual([UInt8](cookie.suffix(135).prefix(5)), [0x05, 0x80, 0x80, 0x81, 0x02])
        XCTAssertEqual([UInt8](cookie.suffix(130)), [UInt8](asc))
    }
}

private final class PCMRecorder: Sendable {
    private let samples = OSAllocatedUnfairLock<[Float]>(initialState: [])

    func record(_ pointer: UnsafePointer<Float>, frames: Int) {
        let count = frames * Int(AudioDecoder.outputChannels)
        let copy = Array(UnsafeBufferPointer(start: pointer, count: count))
        samples.withLock {
            $0 = copy
        }
    }

    func snapshot() -> [Float] {
        samples.withLock { $0 }
    }
}

import CoreMedia
@testable import LemurCam
import XCTest

/// Byte-exact checks on the AVCC block buffer (`[4-byte big-endian length][NAL]`
/// repeated) that `NALProcessor` hands to VideoToolbox, plus NAL-type filter
/// boundaries the existing `NALProcessorTests` leaves open. The existing suite
/// only checks the block buffer's total length; these verify the actual bytes,
/// so a wrong length prefix (e.g. little-endian) would be caught here.
internal final class NALProcessorAVCCTests: XCTestCase {
    private let sps = Data([0x67, 0x42, 0xC0, 0x1E, 0xD9, 0x00, 0xA0, 0x47, 0xFE, 0xC8])
    private let pps = Data([0x68, 0xCE, 0x38, 0x80])

    private func h264() -> NALProcessor {
        NALProcessor(codec: .h264, sps: sps, pps: pps, vps: nil)
    }

    /// Copy the full contents of a block buffer into a byte array for comparison.
    private func contents(of blockBuffer: CMBlockBuffer) throws -> [UInt8] {
        let length = CMBlockBufferGetDataLength(blockBuffer)
        var out = [UInt8](repeating: 0, count: length)
        let status = out.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return OSStatus(-1) }
            return CMBlockBufferCopyDataBytes(
                blockBuffer, atOffset: 0, dataLength: length, destination: base
            )
        }
        return try XCTUnwrap(status == kCMBlockBufferNoErr ? out : nil)
    }

    // MARK: - AVCC byte layout

    func testBlockBufferUsesFourByteBigEndianLengthPrefixes() throws {
        let nal1 = Data([0x65, 0xAA, 0xBB])
        let nal2 = Data([0x61, 0xCC])
        let block = try XCTUnwrap(h264().buildBlockBuffer(nalus: [nal1, nal2]))

        let out = try contents(of: block)
        XCTAssertEqual(out, [0, 0, 0, 3, 0x65, 0xAA, 0xBB, 0, 0, 0, 2, 0x61, 0xCC])
    }

    func testBlockBufferEncodesLargeLengthBigEndian() throws {
        // A 300-byte NAL exercises the high length bytes: 300 = 0x0000012C.
        let payload = Data(repeating: 0x9A, count: 300)
        let block = try XCTUnwrap(h264().buildBlockBuffer(nalus: [payload]))

        let out = try contents(of: block)
        XCTAssertEqual(Array(out.prefix(4)), [0x00, 0x00, 0x01, 0x2C])
        XCTAssertEqual(out.count, 4 + 300)
        XCTAssertEqual(Array(out.suffix(300)), Array(payload))
    }

    func testBlockBufferSingleByteNALLengthPrefix() throws {
        let block = try XCTUnwrap(h264().buildBlockBuffer(nalus: [Data([0x65])]))
        let out = try contents(of: block)
        XCTAssertEqual(out, [0, 0, 0, 1, 0x65])
    }

    // MARK: - NAL-type filter boundaries

    func testH264KeepsUnspecifiedAndReservedTypes() {
        let processor = h264()
        XCTAssertTrue(processor.shouldKeepNAL(Data([0x00])))  // type 0 (unspecified)
        XCTAssertTrue(processor.shouldKeepNAL(Data([0x0B])))  // type 11
        XCTAssertTrue(processor.shouldKeepNAL(Data([0x0C])))  // type 12
    }

    func testH265KeepsTypesAboveSEIRange() {
        let processor = NALProcessor(codec: .h265, sps: sps, pps: pps, vps: Data([0x40, 0x01]))
        // Dropped range is 32–40; the next type up must be kept.
        // type 41 → first byte 0x52, type 47 → 0x5E ((0x5E >> 1) & 0x3F = 47).
        XCTAssertTrue(processor.shouldKeepNAL(Data([0x52, 0x01])))
        XCTAssertTrue(processor.shouldKeepNAL(Data([0x5E, 0x01])))
    }

    // MARK: - Data slice handling

    /// NAL bytes commonly arrive as `Data` slices (sub-ranges of a larger packet
    /// buffer) whose `startIndex` is non-zero. `shouldKeepNAL` reads the header at
    /// `startIndex`, not offset 0, so a slice is classified by its own first byte —
    /// a hard-coded `[0]` would read the wrong byte or trap on an out-of-range index.
    func testShouldKeepNALReadsHeaderAtSliceStartIndex() {
        let processor = h264()
        // SEI header (0x06) sits at the slice start; the leading bytes are a prior NAL.
        let sei = Data([0xFF, 0xFF, 0x06])[2...]
        XCTAssertFalse(processor.shouldKeepNAL(sei))
        // IDR-slice header (0x65) at a non-zero start index must still be kept.
        let idr = Data([0x00, 0x65])[1...]
        XCTAssertTrue(processor.shouldKeepNAL(idr))
    }

    /// `buildBlockBuffer` length-prefixes and copies each NAL by its slice bounds,
    /// not the backing buffer — a sliced NAL encodes its own byte count and bytes.
    func testBlockBufferHandlesSlicedNALBytes() throws {
        let backing = Data([0xAA, 0xBB, 0x65, 0xCC, 0xDD])
        let nal = backing[2...4] // [0x65, 0xCC, 0xDD], startIndex 2
        let block = try XCTUnwrap(h264().buildBlockBuffer(nalus: [nal]))

        let out = try contents(of: block)
        XCTAssertEqual(out, [0, 0, 0, 3, 0x65, 0xCC, 0xDD])
    }

    // MARK: - Block-owned memory lifetime

    /// The block buffer holds its own copy of the NAL bytes: the contents must stay
    /// correct after the source `Data` values are released. This guards the
    /// single-copy path that writes directly into block-owned memory — if it ever
    /// referenced the source bytes instead of copying, this read-back would be wrong
    /// (or a use-after-free).
    func testBlockBufferOwnsBytesAfterSourceReleased() throws {
        // Built in a helper so the source NAL `Data` values are out of scope (and
        // eligible for release) by the time we read the block buffer back.
        let block = try buildTwoNALBlock()

        let out = try contents(of: block)
        XCTAssertEqual(out.count, 4 + 3 + 4 + 64)
        XCTAssertEqual(Array(out.prefix(7)), [0, 0, 0, 3, 0x65, 0xAA, 0xBB])
        XCTAssertEqual(Array(out[7..<11]), [0, 0, 0, 64])
        XCTAssertEqual(Array(out.suffix(64)), Array(repeating: 0x42, count: 64))
    }

    private func buildTwoNALBlock() throws -> CMBlockBuffer {
        let nal1 = Data([0x65, 0xAA, 0xBB])
        let nal2 = Data(repeating: 0x42, count: 64)
        return try XCTUnwrap(h264().buildBlockBuffer(nalus: [nal1, nal2]))
    }

    /// Build, read, and release many block buffers so the custom block source's
    /// FreeBlock callback runs on every iteration. A bad free (double-free / leak /
    /// wrong deallocator pairing) tends to surface as a crash here, especially under
    /// the address sanitizer.
    func testRepeatedBuildAndReleaseExercisesFreePath() throws {
        for index in 0..<500 {
            let payload = (index % 32) + 1
            let nal = Data(repeating: UInt8(truncatingIfNeeded: index), count: payload)
            let block = try XCTUnwrap(h264().buildBlockBuffer(nalus: [nal]))
            XCTAssertEqual(CMBlockBufferGetDataLength(block), 4 + payload)
        }
    }
}

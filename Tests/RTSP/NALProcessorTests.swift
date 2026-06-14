import CoreMedia
@testable import LemurCam
import XCTest

internal final class NALProcessorTests: XCTestCase {

    // Minimal valid H.264 SPS for 16x16 Baseline profile
    // Profile IDC=66 (Baseline), Level=30, 16x16 resolution
    private let minimalSPS = Data([
        0x67, 0x42, 0xC0, 0x1E, 0xD9, 0x00, 0xA0, 0x47, 0xFE, 0xC8
    ])

    // Minimal valid H.264 PPS
    private let minimalPPS = Data([
        0x68, 0xCE, 0x38, 0x80
    ])

    private func makeH264Processor() -> NALProcessor {
        NALProcessor(codec: .h264, sps: minimalSPS, pps: minimalPPS, vps: nil)
    }

    // MARK: - shouldKeepNAL (H.264)

    func testH264KeepsSliceNALs() {
        let processor = makeH264Processor()

        // NAL type 1 (non-IDR slice) — first byte & 0x1F = 1
        XCTAssertTrue(processor.shouldKeepNAL(Data([0x61])))
        // NAL type 5 (IDR slice) — first byte & 0x1F = 5
        XCTAssertTrue(processor.shouldKeepNAL(Data([0x65])))
    }

    func testH264DropsSEI() {
        let processor = makeH264Processor()
        // NAL type 6 (SEI) — first byte & 0x1F = 6
        XCTAssertFalse(processor.shouldKeepNAL(Data([0x06])))
    }

    func testH264DropsSPS() {
        let processor = makeH264Processor()
        // NAL type 7 (SPS) — first byte & 0x1F = 7
        XCTAssertFalse(processor.shouldKeepNAL(Data([0x67])))
    }

    func testH264DropsPPS() {
        let processor = makeH264Processor()
        // NAL type 8 (PPS) — first byte & 0x1F = 8
        XCTAssertFalse(processor.shouldKeepNAL(Data([0x68])))
    }

    func testH264DropsAUD() {
        let processor = makeH264Processor()
        // NAL type 9 (AUD) — first byte & 0x1F = 9
        XCTAssertFalse(processor.shouldKeepNAL(Data([0x09])))
    }

    func testH264KeepsHigherTypes() {
        let processor = makeH264Processor()
        // NAL type 10 — should be kept
        XCTAssertTrue(processor.shouldKeepNAL(Data([0x0A])))
    }

    func testH264RejectsEmptyData() {
        let processor = makeH264Processor()
        XCTAssertFalse(processor.shouldKeepNAL(Data()))
    }

    // MARK: - shouldKeepNAL (H.265)

    func testH265KeepsSliceNALs() {
        let processor = NALProcessor(codec: .h265, sps: minimalSPS, pps: minimalPPS, vps: Data([0x40, 0x01]))

        // H.265: nalType = (firstByte >> 1) & 0x3F
        // NAL type 1 (TRAIL_R) — first byte = 0x02 → (0x02 >> 1) & 0x3F = 1
        XCTAssertTrue(processor.shouldKeepNAL(Data([0x02, 0x01])))
        // NAL type 19 (IDR_W_RADL) — first byte = 0x26 → (0x26 >> 1) & 0x3F = 19
        XCTAssertTrue(processor.shouldKeepNAL(Data([0x26, 0x01])))
    }

    func testH265DropsVPS() {
        let processor = NALProcessor(codec: .h265, sps: minimalSPS, pps: minimalPPS, vps: Data([0x40, 0x01]))
        // NAL type 32 (VPS) — first byte = 0x40 → (0x40 >> 1) & 0x3F = 32
        XCTAssertFalse(processor.shouldKeepNAL(Data([0x40, 0x01])))
    }

    func testH265DropsSPS() {
        let processor = NALProcessor(codec: .h265, sps: minimalSPS, pps: minimalPPS, vps: Data([0x40, 0x01]))
        // NAL type 33 (SPS) — first byte = 0x42 → (0x42 >> 1) & 0x3F = 33
        XCTAssertFalse(processor.shouldKeepNAL(Data([0x42, 0x01])))
    }

    func testH265DropsSEI() {
        let processor = NALProcessor(codec: .h265, sps: minimalSPS, pps: minimalPPS, vps: Data([0x40, 0x01]))
        // NAL type 39 (SEI prefix) — first byte = 0x4E → (0x4E >> 1) & 0x3F = 39
        XCTAssertFalse(processor.shouldKeepNAL(Data([0x4E, 0x01])))
        // NAL type 40 (SEI suffix) — first byte = 0x50 → (0x50 >> 1) & 0x3F = 40
        XCTAssertFalse(processor.shouldKeepNAL(Data([0x50, 0x01])))
    }

    func testH265KeepsBelowVPS() {
        let processor = NALProcessor(codec: .h265, sps: minimalSPS, pps: minimalPPS, vps: Data([0x40, 0x01]))
        // NAL type 31 — first byte = 0x3E → (0x3E >> 1) & 0x3F = 31
        XCTAssertTrue(processor.shouldKeepNAL(Data([0x3E, 0x01])))
    }

    // MARK: - buildBlockBuffer

    func testBuildBlockBufferCreatesAVCCData() {
        let processor = makeH264Processor()
        let nal1 = Data([0x65, 0xAA, 0xBB]) // 3-byte NAL
        let nal2 = Data([0x61, 0xCC])        // 2-byte NAL

        let blockBuffer = processor.buildBlockBuffer(nalus: [nal1, nal2])
        XCTAssertNotNil(blockBuffer)

        // Expected: [4-byte length BE][nal1][4-byte length BE][nal2]
        // = [0,0,0,3, 0x65,0xAA,0xBB, 0,0,0,2, 0x61,0xCC]
        // Total = 13 bytes
        guard let blockBuffer else {
            return
        }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        XCTAssertEqual(length, 13)
    }

    func testBuildBlockBufferReturnsNilForEmptyInput() {
        let processor = makeH264Processor()
        XCTAssertNil(processor.buildBlockBuffer(nalus: []))
    }

    func testBuildBlockBufferSingleNAL() {
        let processor = makeH264Processor()
        let nal = Data([0x65, 0x01, 0x02, 0x03, 0x04]) // 5-byte NAL

        let blockBuffer = processor.buildBlockBuffer(nalus: [nal])
        XCTAssertNotNil(blockBuffer)

        // Expected: [0,0,0,5][5 bytes] = 9 bytes
        guard let blockBuffer else {
            return
        }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        XCTAssertEqual(length, 9)
    }
}

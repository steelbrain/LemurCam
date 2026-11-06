import CoreMedia
import CoreVideo
@testable import LemurCam
import XCTest

/// The writer cached one format description per frame size and pixel format, but a
/// description also carries the frame's color tags. Switching to a camera at the same
/// size with other tags (BT.709 then BT.601, or an untagged SD stream that
/// VideoToolbox takes for 601) left every frame failing to become a sample buffer, so
/// apps using the virtual camera saw only the placeholder.
internal final class VirtualCameraFrameWriterTests: XCTestCase {
    func testAFrameWithOtherColorTagsGetsItsOwnFormatDescription() throws {
        let writer = VirtualCameraFrameWriter(model: LemurCamModel(consumerProbe: { _ in false }))
        let hd = try Self.frame(tagged: .bt709)
        let sd = try Self.frame(tagged: .bt601)

        let first = try XCTUnwrap(writer.sampleBuffer(for: hd))
        let second = try XCTUnwrap(
            writer.sampleBuffer(for: sd), "a frame tagged 601 after one tagged 709 at the same size"
        )
        let third = try XCTUnwrap(writer.sampleBuffer(for: hd))

        for (sample, frame) in [(first, hd), (second, sd), (third, hd)] {
            let description = try XCTUnwrap(CMSampleBufferGetFormatDescription(sample))
            XCTAssertTrue(CMVideoFormatDescriptionMatchesImageBuffer(description, imageBuffer: frame))
        }
    }

    func testFramesThatMatchReuseTheCachedDescription() throws {
        let writer = VirtualCameraFrameWriter(model: LemurCamModel(consumerProbe: { _ in false }))
        let one = try Self.frame(tagged: .bt709)
        let two = try Self.frame(tagged: .bt709)

        let first = try XCTUnwrap(writer.sampleBuffer(for: one).flatMap(CMSampleBufferGetFormatDescription))
        let second = try XCTUnwrap(writer.sampleBuffer(for: two).flatMap(CMSampleBufferGetFormatDescription))

        XCTAssertIdentical(first, second, "a matching frame keeps the cached description")
    }

    private enum ColorTags {
        case bt709, bt601

        var matrix: CFString {
            self == .bt709 ? kCVImageBufferYCbCrMatrix_ITU_R_709_2 : kCVImageBufferYCbCrMatrix_ITU_R_601_4
        }

        var primaries: CFString {
            self == .bt709 ? kCVImageBufferColorPrimaries_ITU_R_709_2 : kCVImageBufferColorPrimaries_SMPTE_C
        }
    }

    /// A 64x64 NV12 video-range frame, as VideoToolbox decodes, with color tags.
    private static func frame(tagged tags: ColorTags) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, 64, 64, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        let frame = try XCTUnwrap(buffer)
        CVBufferSetAttachment(frame, kCVImageBufferYCbCrMatrixKey, tags.matrix, .shouldPropagate)
        CVBufferSetAttachment(frame, kCVImageBufferColorPrimariesKey, tags.primaries, .shouldPropagate)
        CVBufferSetAttachment(
            frame, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate
        )
        return frame
    }
}

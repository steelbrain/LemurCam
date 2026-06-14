import CoreGraphics
import CoreImage
import CoreVideo
@testable import LemurCam
import XCTest

/// Covers the preview downscale helpers LemurCam uses to shrink decoded
/// frames before the CGImage readback. The factor math is pure; the render test
/// confirms the produced CGImage is actually downscaled to the target height (and
/// left untouched when the source is already small), using a software `CIContext`
/// so it runs headlessly.
internal final class PreviewDownscaleTests: XCTestCase {

    // MARK: - Scale factor

    func testFactorDownscalesTallSource() {
        let factor = PreviewFrameRenderer.previewDownscaleFactor(sourceHeight: 1080, maxHeight: 360)
        XCTAssertEqual(factor, 360.0 / 1080.0, accuracy: 0.0001)
    }

    func testFactorNeverUpscalesSmallSource() {
        XCTAssertEqual(PreviewFrameRenderer.previewDownscaleFactor(sourceHeight: 240, maxHeight: 360), 1)
    }

    func testFactorIsOneWhenExactlyAtMax() {
        XCTAssertEqual(PreviewFrameRenderer.previewDownscaleFactor(sourceHeight: 360, maxHeight: 360), 1)
    }

    func testFactorIsOneForNonPositiveMax() {
        XCTAssertEqual(PreviewFrameRenderer.previewDownscaleFactor(sourceHeight: 1080, maxHeight: 0), 1)
    }

    func testFactorIsOneForNonFiniteSource() {
        XCTAssertEqual(PreviewFrameRenderer.previewDownscaleFactor(sourceHeight: .infinity, maxHeight: 360), 1)
    }

    // MARK: - Rendered image dimensions

    func testRenderDownscalesLargeFrameToMaxHeight() throws {
        let buffer = try makePixelBuffer(width: 1920, height: 1080)
        let image = try XCTUnwrap(PreviewFrameRenderer.downscaledPreviewImage(
            from: buffer, context: CIContext(), maxHeight: 360
        ))
        // Allow ±1px for the float-scale → integer-pixel rounding in createCGImage.
        XCTAssertLessThanOrEqual(image.height, 360)
        XCTAssertGreaterThanOrEqual(image.height, 359)
        XCTAssertEqual(Double(image.width) / Double(image.height), 1920.0 / 1080.0, accuracy: 0.02)
    }

    func testRenderLeavesSmallFrameUnscaled() throws {
        let buffer = try makePixelBuffer(width: 320, height: 240)
        let image = try XCTUnwrap(PreviewFrameRenderer.downscaledPreviewImage(
            from: buffer, context: CIContext(), maxHeight: 360
        ))
        XCTAssertEqual(image.width, 320)
        XCTAssertEqual(image.height, 240)
    }

    // MARK: - Helpers

    private func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            attrs as CFDictionary, &buffer
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        return try XCTUnwrap(buffer)
    }
}

import CoreVideo
@testable import LemurCam
import XCTest

/// The placeholder is what every consuming app sees when the camera is
/// connecting, reconnecting, or errored, so its output must match the virtual
/// camera's wire format: an IOSurface-backed NV12 buffer at the requested size.
/// The drawn text content isn't asserted (it's cosmetic); the buffer contract is.
internal final class PlaceholderRendererTests: XCTestCase {

    func testRenderProducesNV12BufferAtRequestedSize() throws {
        let buffer = try XCTUnwrap(PlaceholderRenderer.render(text: "No Signal", width: 1280, height: 720))

        XCTAssertEqual(CVPixelBufferGetWidth(buffer), 1280)
        XCTAssertEqual(CVPixelBufferGetHeight(buffer), 720)
        XCTAssertEqual(
            CVPixelBufferGetPixelFormatType(buffer),
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
    }

    func testRenderHonorsDifferentDimensions() throws {
        let buffer = try XCTUnwrap(PlaceholderRenderer.render(text: "Connecting", width: 640, height: 480))

        XCTAssertEqual(CVPixelBufferGetWidth(buffer), 640)
        XCTAssertEqual(CVPixelBufferGetHeight(buffer), 480)
    }

    /// Empty text draws an empty line rather than aborting the render, so a
    /// correctly-sized buffer is still produced.
    func testRenderEmptyTextStillProducesBuffer() throws {
        let buffer = try XCTUnwrap(PlaceholderRenderer.render(text: "", width: 320, height: 240))

        XCTAssertEqual(CVPixelBufferGetWidth(buffer), 320)
        XCTAssertEqual(CVPixelBufferGetHeight(buffer), 240)
    }

    func testRenderedBufferIsIOSurfaceBacked() throws {
        let buffer = try XCTUnwrap(PlaceholderRenderer.render(text: "Hi", width: 320, height: 240))

        XCTAssertNotNil(CVPixelBufferGetIOSurface(buffer))
    }
}

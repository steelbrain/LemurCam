import CoreMedia
@testable import LemurCam
import os
import XCTest

/// Locks the size of the app's own placeholder ("Connecting in LemurCam" and the
/// like). It used to be fixed at the Resolution setting read when the app started,
/// so a change in Settings left it at the old size. It now follows the setting
/// each time a placeholder starts; the extension scales it to the format of the
/// app using the camera either way.
internal final class FrameGeneratorTests: XCTestCase {
    /// A model that makes no CMIO calls on the fake IDs of other tests.
    private static func offlineModel() -> LemurCamModel {
        LemurCamModel(consumerProbe: { _ in false }, consumerObserver: { _ in nil }, formatWriter: { _, _ in })
    }

    func testThePlaceholderIsDrawnAtTheSettingWhenItStarts() throws {
        let setting = OSAllocatedUnfairLock(initialState: LemurCamConfig.Resolution.hd720)
        let model = Self.offlineModel()
        let generator = FrameGenerator(model: model, resolution: { setting.withLock { $0 } })
        defer { generator.stop() }

        generator.start(message: "Connecting in LemurCam")
        let first = try XCTUnwrap(generator.placeholderDimensions)
        XCTAssertEqual(first.width, 1280)
        XCTAssertEqual(first.height, 720)

        setting.withLock { $0 = .qhd1440 }
        generator.start(message: "Reconnecting in LemurCam")
        let second = try XCTUnwrap(generator.placeholderDimensions)
        XCTAssertEqual(second.width, 2560)
        XCTAssertEqual(second.height, 1440)
    }

    func testAStoppedGeneratorReportsNoPlaceholder() {
        let model = Self.offlineModel()
        let generator = FrameGenerator(model: model, resolution: { .hd720 })

        generator.start()
        generator.stop()

        XCTAssertNil(generator.placeholderDimensions)
        XCTAssertNil(generator.placeholderMessage)
    }
}

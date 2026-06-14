@testable import LemurCam
import XCTest

/// Pins the resolution/frame-rate enum tables. The extension's stream format is
/// derived from these width/height values, so a wrong mapping ships a mis-sized
/// virtual camera. These are pure value mappings — no shared-defaults access — so
/// they never touch the app-group state a running app/extension relies on.
internal final class LemurCamConfigTests: XCTestCase {

    // MARK: - Resolution

    func testResolutionDimensions() {
        XCTAssertEqual(LemurCamConfig.Resolution.hd720.width, 1280)
        XCTAssertEqual(LemurCamConfig.Resolution.hd720.height, 720)
        XCTAssertEqual(LemurCamConfig.Resolution.hd1080.width, 1920)
        XCTAssertEqual(LemurCamConfig.Resolution.hd1080.height, 1080)
        XCTAssertEqual(LemurCamConfig.Resolution.qhd1440.width, 2560)
        XCTAssertEqual(LemurCamConfig.Resolution.qhd1440.height, 1440)
        XCTAssertEqual(LemurCamConfig.Resolution.uhd4k.width, 3840)
        XCTAssertEqual(LemurCamConfig.Resolution.uhd4k.height, 2160)
    }

    func testResolutionRawValuesAndID() {
        XCTAssertEqual(LemurCamConfig.Resolution.hd720.rawValue, "720p")
        XCTAssertEqual(LemurCamConfig.Resolution.hd1080.rawValue, "1080p")
        XCTAssertEqual(LemurCamConfig.Resolution.qhd1440.rawValue, "1440p")
        XCTAssertEqual(LemurCamConfig.Resolution.uhd4k.rawValue, "4K")
        // id mirrors rawValue (used as the SwiftUI Identifiable key).
        for resolution in LemurCamConfig.Resolution.allCases {
            XCTAssertEqual(resolution.id, resolution.rawValue)
        }
    }

    func testResolutionCaseIterableOrder() {
        XCTAssertEqual(
            LemurCamConfig.Resolution.allCases,
            [.hd720, .hd1080, .qhd1440, .uhd4k]
        )
    }

    func testResolutionRoundTripsThroughRawValue() {
        for resolution in LemurCamConfig.Resolution.allCases {
            XCTAssertEqual(LemurCamConfig.Resolution(rawValue: resolution.rawValue), resolution)
        }
    }

    func testResolutionWidthsAreLandscapeAndAscending() {
        let widths = LemurCamConfig.Resolution.allCases.map(\.width)
        XCTAssertEqual(widths, widths.sorted())
        for resolution in LemurCamConfig.Resolution.allCases {
            XCTAssertGreaterThan(resolution.width, resolution.height, "\(resolution) is not landscape")
        }
    }

    // MARK: - FrameRate

    func testFrameRateRawValuesAndLabels() {
        XCTAssertEqual(LemurCamConfig.FrameRate.fps30.rawValue, 30)
        XCTAssertEqual(LemurCamConfig.FrameRate.fps60.rawValue, 60)
        XCTAssertEqual(LemurCamConfig.FrameRate.fps30.label, "30 fps")
        XCTAssertEqual(LemurCamConfig.FrameRate.fps60.label, "60 fps")
    }

    func testFrameRateIDMirrorsRawValue() {
        for rate in LemurCamConfig.FrameRate.allCases {
            XCTAssertEqual(rate.id, rate.rawValue)
        }
    }

    func testFrameRateCaseIterableOrder() {
        XCTAssertEqual(LemurCamConfig.FrameRate.allCases, [.fps30, .fps60])
    }

    func testFrameRateRoundTripsThroughRawValue() {
        for rate in LemurCamConfig.FrameRate.allCases {
            XCTAssertEqual(LemurCamConfig.FrameRate(rawValue: rate.rawValue), rate)
        }
        // 0 is the "unset" sentinel UserDefaults returns; it is never a valid rate.
        XCTAssertNil(LemurCamConfig.FrameRate(rawValue: 0))
    }
}

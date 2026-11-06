import CoreMedia
@testable import LemurCam
import XCTest

/// Pins the camera's format table. The extension advertises one format per
/// resolution, and CMIO names a format by its index, so the index must map to the
/// same resolution in the extension and the app. A frame duration a client sets
/// must map to a frame rate the formats offer, or be refused.
internal final class StreamFormatTableTests: XCTestCase {

    // MARK: - Format indices

    func testFormatIndicesFollowTheResolutionOrder() {
        XCTAssertEqual(StreamFormatTable.resolutions, [.hd720, .hd1080, .qhd1440, .uhd4k])
        for (index, resolution) in StreamFormatTable.resolutions.enumerated() {
            XCTAssertEqual(StreamFormatTable.formatIndex(of: resolution), index)
            XCTAssertEqual(StreamFormatTable.resolution(atFormatIndex: index), resolution)
        }
    }

    func testAnIndexPastEitherEndNamesNoFormat() {
        XCTAssertNil(StreamFormatTable.resolution(atFormatIndex: -1))
        XCTAssertNil(StreamFormatTable.resolution(atFormatIndex: StreamFormatTable.resolutions.count))
        XCTAssertNil(StreamFormatTable.resolution(atFormatIndex: .max))
        XCTAssertNil(StreamFormatTable.resolution(atFormatIndex: .min))
    }

    // MARK: - Frame durations

    func testEveryFormatOffersBothRatesFastestFirst() {
        XCTAssertEqual(
            StreamFormatTable.validFrameDurations,
            [CMTime(value: 1, timescale: 60), CMTime(value: 1, timescale: 30)]
        )
        XCTAssertEqual(StreamFormatTable.minFrameDuration, CMTime(value: 1, timescale: 60))
        XCTAssertEqual(StreamFormatTable.maxFrameDuration, CMTime(value: 1, timescale: 30))
        XCTAssertEqual(StreamFormatTable.fastestFrameRate, .fps60)
    }

    func testExactDurationsMapToTheirRates() {
        XCTAssertEqual(StreamFormatTable.frameRate(forFrameDuration: CMTime(value: 1, timescale: 30)), .fps30)
        XCTAssertEqual(StreamFormatTable.frameRate(forFrameDuration: CMTime(value: 1, timescale: 60)), .fps60)
    }

    /// A rate converted to a duration arrives in another timescale, or rounded.
    func testDurationsInOtherTimescalesOrRoundedMapToTheNearestRate() {
        XCTAssertEqual(StreamFormatTable.frameRate(forFrameDuration: CMTime(value: 1000, timescale: 30_000)), .fps30)
        XCTAssertEqual(
            StreamFormatTable.frameRate(forFrameDuration: CMTime(value: 33_333_333, timescale: 1_000_000_000)), .fps30
        )
        XCTAssertEqual(StreamFormatTable.frameRate(forFrameDuration: CMTime(value: 1001, timescale: 30_000)), .fps30)
        XCTAssertEqual(StreamFormatTable.frameRate(forFrameDuration: CMTime(value: 1001, timescale: 60_000)), .fps60)
        XCTAssertEqual(
            StreamFormatTable.frameRate(forFrameDuration: CMTime(seconds: 1.0 / 60.0, preferredTimescale: 600)), .fps60
        )
    }

    func testDurationsOfRatesNotOfferedMapToNothing() {
        XCTAssertNil(StreamFormatTable.frameRate(forFrameDuration: CMTime(value: 1, timescale: 25)))
        XCTAssertNil(StreamFormatTable.frameRate(forFrameDuration: CMTime(value: 1, timescale: 24)))
        XCTAssertNil(StreamFormatTable.frameRate(forFrameDuration: CMTime(value: 1, timescale: 45)))
        XCTAssertNil(StreamFormatTable.frameRate(forFrameDuration: CMTime(value: 1, timescale: 120)))
        XCTAssertNil(StreamFormatTable.frameRate(forFrameDuration: CMTime(value: 1, timescale: 1)))
    }

    func testZeroNegativeAndNonNumericDurationsMapToNothing() {
        XCTAssertNil(StreamFormatTable.frameRate(forFrameDuration: .zero))
        XCTAssertNil(StreamFormatTable.frameRate(forFrameDuration: CMTime(value: -1, timescale: 30)))
        XCTAssertNil(StreamFormatTable.frameRate(forFrameDuration: .invalid))
        XCTAssertNil(StreamFormatTable.frameRate(forFrameDuration: .indefinite))
        XCTAssertNil(StreamFormatTable.frameRate(forFrameDuration: .positiveInfinity))
        XCTAssertNil(StreamFormatTable.frameRate(forFrameDuration: .negativeInfinity))
        XCTAssertNil(StreamFormatTable.frameRate(forFrameDuration: CMTime(value: 1, timescale: 0)))
    }

    func testASelectionsDurationRoundTrips() {
        for rate in LemurCamConfig.FrameRate.allCases {
            let selection = StreamFormatSelection(resolution: .hd1080, frameRate: rate)
            XCTAssertEqual(StreamFormatTable.frameRate(forFrameDuration: selection.frameDuration), rate)
            XCTAssertEqual(selection.frameDurationNanoseconds, 1_000_000_000 / UInt64(rate.rawValue))
        }
    }

    // MARK: - Picking a format the app read from CMIO

    func testTheAppFindsTheFormatOfAResolutionByItsSize() {
        let dimensions = StreamFormatTable.resolutions.map {
            CMVideoDimensions(width: $0.width, height: $0.height)
        }
        for (index, resolution) in StreamFormatTable.resolutions.enumerated() {
            XCTAssertEqual(StreamFormatTable.index(of: resolution, among: dimensions), index)
        }
    }

    /// An extension older than the app offered one 1080p format on its sink.
    func testAResolutionTheStreamDoesNotOfferHasNoIndex() {
        let oldSink = [CMVideoDimensions(width: 1920, height: 1080)]
        XCTAssertEqual(StreamFormatTable.index(of: .hd1080, among: oldSink), 0)
        XCTAssertNil(StreamFormatTable.index(of: .uhd4k, among: oldSink))
        XCTAssertNil(StreamFormatTable.index(of: .hd720, among: []))
    }

    // MARK: - Pass-through

    func testOnlyAFrameOfTheTargetSizeAndPixelFormatPassesThrough() {
        let nv12 = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        XCTAssertTrue(StreamFormatTable.passesThrough(width: 1920, height: 1080, pixelFormat: nv12, to: .hd1080))
        XCTAssertFalse(StreamFormatTable.passesThrough(width: 1280, height: 720, pixelFormat: nv12, to: .hd1080))
        XCTAssertFalse(StreamFormatTable.passesThrough(width: 1920, height: 1088, pixelFormat: nv12, to: .hd1080))
        XCTAssertFalse(StreamFormatTable.passesThrough(width: 2304, height: 1296, pixelFormat: nv12, to: .hd1080))
        XCTAssertFalse(
            StreamFormatTable.passesThrough(
                width: 1920, height: 1080, pixelFormat: kCVPixelFormatType_32BGRA, to: .hd1080
            )
        )
        XCTAssertFalse(
            StreamFormatTable.passesThrough(
                width: 1920, height: 1080, pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, to: .hd1080
            )
        )
    }

    // MARK: - Defaults

    func testTheExtensionStartsInTheSettingsDefaults() {
        XCTAssertEqual(
            LemurCamConfig.defaultFormat,
            StreamFormatSelection(resolution: .hd1080, frameRate: .fps60)
        )
    }

    func testPlaceholderTextScalesWithTheFrameHeight() {
        XCTAssertEqual(PlaceholderRenderer.fontSize(64, forHeight: 1080), 64, accuracy: 0.001)
        XCTAssertEqual(PlaceholderRenderer.fontSize(64, forHeight: 2160), 128, accuracy: 0.001)
        XCTAssertEqual(PlaceholderRenderer.fontSize(48, forHeight: 720), 32, accuracy: 0.001)
        XCTAssertGreaterThan(PlaceholderRenderer.fontSize(48, forHeight: 0), 0)
    }
}

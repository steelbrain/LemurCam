@testable import LemurCam
import XCTest

/// Locks how the processor behaves without a usable format description. It used to
/// log a warning for every dropped frame until parameter sets arrived, and a format
/// description that failed to build was never retried, because IPCamKit reports
/// parameter sets only when they change. The warning is now logged once per stretch
/// without a format description, and keyframes retry the build from the stored sets.
internal final class NALProcessorFormatDescriptionTests: XCTestCase {
    private let missingWarning = "No format description available"
    private let buildFailure = "Failed to create format description"
    private let recorder = LogLineRecorder()

    override func setUp() {
        super.setUp()
        recorder.install()
    }

    override func tearDown() {
        recorder.uninstall()
        super.tearDown()
    }

    func testMissingFormatDescriptionIsLoggedOnce() {
        let processor = NALProcessor(codec: .h264, sps: Data(), pps: Data(), vps: nil)

        for _ in 0..<5 {
            XCTAssertNil(processor.process(H264TestStream.deltaFrame()))
        }
        XCTAssertNil(processor.process(H264TestStream.keyframe()))

        XCTAssertEqual(recorder.count(startingWith: missingWarning), 1)
    }

    /// Once parameter sets arrive the stretch ends; if a later change leaves the
    /// stream without a format description again, that new stretch logs once too.
    func testWarningIsLoggedAgainAfterTheFormatDescriptionIsLostAgain() {
        let processor = NALProcessor(codec: .h264, sps: Data(), pps: Data(), vps: nil)
        XCTAssertNil(processor.process(H264TestStream.deltaFrame()))
        XCTAssertNil(processor.process(H264TestStream.deltaFrame()))

        var withSets = H264TestStream.keyframe()
        withSets.sps = H264TestStream.sps
        withSets.pps = H264TestStream.pps
        XCTAssertNotNil(processor.process(withSets), "in-band parameter sets must build a format description")

        var broken = H264TestStream.keyframe()
        broken.sps = H264TestStream.invalidSPS
        broken.pps = H264TestStream.pps
        XCTAssertNil(processor.process(broken))
        XCTAssertNil(processor.process(H264TestStream.deltaFrame()))

        XCTAssertEqual(recorder.count(startingWith: missingWarning), 2)
    }

    /// A build that failed is retried on each keyframe, not on every frame.
    func testFailedBuildIsRetriedOnKeyframes() {
        let processor = NALProcessor(
            codec: .h264, sps: H264TestStream.invalidSPS, pps: H264TestStream.pps, vps: nil
        )
        XCTAssertEqual(recorder.count(startingWith: buildFailure), 1, "the initial build fails")

        XCTAssertNil(processor.process(H264TestStream.deltaFrame()))
        XCTAssertNil(processor.process(H264TestStream.deltaFrame()))
        XCTAssertEqual(recorder.count(startingWith: buildFailure), 1, "delta frames must not retry")

        XCTAssertNil(processor.process(H264TestStream.keyframe()))
        XCTAssertNil(processor.process(H264TestStream.keyframe()))
        XCTAssertEqual(recorder.count(startingWith: buildFailure), 3, "each keyframe must retry")
    }

    /// The frame that delivers new parameter sets builds once; the keyframe retry
    /// must not build a second time in the same call.
    func testParameterSetChangeOnAKeyframeBuildsOnce() {
        let processor = NALProcessor(codec: .h264, sps: Data(), pps: Data(), vps: nil)
        var broken = H264TestStream.keyframe()
        broken.sps = H264TestStream.invalidSPS
        broken.pps = H264TestStream.pps

        XCTAssertNil(processor.process(broken))

        XCTAssertEqual(recorder.count(startingWith: buildFailure), 1)
    }
}

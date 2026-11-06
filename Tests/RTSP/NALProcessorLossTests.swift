@testable import LemurCam
import XCTest

/// Locks the keyframe gate after packet loss. IPCamKit reports lost packets in
/// `PublicVideoFrame.loss`; the frames after a loss can reference pictures that never
/// arrived, so decoding them smears the picture until the next keyframe. The
/// processor used to ignore `loss` and pass those frames on; it now drops them and
/// resumes at the next keyframe.
internal final class NALProcessorLossTests: XCTestCase {

    private func makeProcessor() -> NALProcessor {
        NALProcessor(codec: .h264, sps: H264TestStream.sps, pps: H264TestStream.pps, vps: nil)
    }

    func testDeltaFramesAfterAKeyframeAreDecoded() {
        let processor = makeProcessor()

        XCTAssertNotNil(processor.process(H264TestStream.keyframe()))
        XCTAssertNotNil(processor.process(H264TestStream.deltaFrame()))
        XCTAssertNotNil(processor.process(H264TestStream.deltaFrame()))
    }

    func testDeltaFramesBeforeTheFirstKeyframeAreDropped() {
        let processor = makeProcessor()

        XCTAssertNil(processor.process(H264TestStream.deltaFrame()))
        XCTAssertNotNil(processor.process(H264TestStream.keyframe()))
    }

    func testLossDropsDeltaFramesUntilTheNextKeyframe() {
        let processor = makeProcessor()
        XCTAssertNotNil(processor.process(H264TestStream.keyframe()))
        XCTAssertNotNil(processor.process(H264TestStream.deltaFrame()))

        XCTAssertNil(processor.process(H264TestStream.deltaFrame(loss: 3)), "the frame after a loss must be dropped")
        XCTAssertNil(processor.process(H264TestStream.deltaFrame()), "delta frames stay dropped until a keyframe")
        XCTAssertNil(processor.process(H264TestStream.deltaFrame()))

        let resumed = processor.process(H264TestStream.keyframe())
        XCTAssertEqual(resumed?.isKeyframe, true, "decoding resumes at the next keyframe")
        XCTAssertNotNil(processor.process(H264TestStream.deltaFrame()), "and continues with the frames after it")
    }

    /// A keyframe decodes on its own, so loss right before one needs no wait.
    func testLossBeforeAKeyframeDoesNotDropIt() {
        let processor = makeProcessor()
        XCTAssertNotNil(processor.process(H264TestStream.keyframe()))

        XCTAssertNotNil(processor.process(H264TestStream.keyframe(loss: 1)))
        XCTAssertNotNil(processor.process(H264TestStream.deltaFrame()))
    }

    func testLossWhileWaitingForAKeyframeKeepsWaiting() {
        let processor = makeProcessor()

        XCTAssertNil(processor.process(H264TestStream.deltaFrame(loss: 2)))
        XCTAssertNil(processor.process(H264TestStream.deltaFrame()))
        XCTAssertNotNil(processor.process(H264TestStream.keyframe()))
    }
}

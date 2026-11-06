import CoreMedia
@testable import LemurCam
import XCTest

/// Locks session (re)creation in `VideoDecoder`. It stored the format description
/// before creating the session, so after a failed creation every later frame with
/// that format compared equal, `decode` found no session, and video stayed frozen
/// with no retry. A failed creation now leaves no remembered format, and the next
/// keyframe retries it. A format VideoToolbox has no decoder for stands in for a
/// failing creation.
internal final class VideoDecoderSessionRetryTests: XCTestCase {
    private let creationFailure = "Failed to create decompression session"
    private let creation = "Created decompression session"
    private let recorder = LogLineRecorder()

    override func setUp() {
        super.setUp()
        recorder.install()
    }

    override func tearDown() {
        recorder.uninstall()
        super.tearDown()
    }

    private func undecodableFormat() throws -> CMVideoFormatDescription {
        var description: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, codecType: 0x6162_6364, // 'abcd'
            width: 64, height: 64, extensions: nil, formatDescriptionOut: &description
        )
        XCTAssertEqual(status, noErr)
        return try XCTUnwrap(description)
    }

    private func h264Format() throws -> CMVideoFormatDescription {
        let processor = NALProcessor(codec: .h264, sps: H264TestStream.sps, pps: H264TestStream.pps, vps: nil)
        return try XCTUnwrap(processor.process(H264TestStream.keyframe())).formatDescription
    }

    func testFailedCreationIsRetriedOnTheNextKeyframe() throws {
        let decoder = VideoDecoder()
        let format = try undecodableFormat()

        decoder.updateFormatDescription(format, isKeyframe: true)
        XCTAssertFalse(decoder.hasSession)
        XCTAssertEqual(recorder.count(startingWith: creationFailure), 1)

        decoder.updateFormatDescription(format, isKeyframe: false)
        decoder.updateFormatDescription(format, isKeyframe: false)
        XCTAssertEqual(recorder.count(startingWith: creationFailure), 1, "delta frames must not retry")

        decoder.updateFormatDescription(format, isKeyframe: true)
        XCTAssertEqual(recorder.count(startingWith: creationFailure), 2, "the same format must retry on a keyframe")
        decoder.tearDown()
    }

    func testSessionIsCreatedOnceForAnUnchangedFormat() throws {
        let decoder = VideoDecoder()
        let format = try h264Format()

        decoder.updateFormatDescription(format, isKeyframe: true)
        decoder.updateFormatDescription(format, isKeyframe: false)
        decoder.updateFormatDescription(format, isKeyframe: true)

        XCTAssertTrue(decoder.hasSession)
        XCTAssertEqual(recorder.count(startingWith: creation), 1)
        decoder.tearDown()
    }

    /// After a failed creation, a keyframe in a decodable format recovers.
    func testKeyframeWithADecodableFormatRecoversAfterAFailure() throws {
        let decoder = VideoDecoder()
        decoder.updateFormatDescription(try undecodableFormat(), isKeyframe: true)
        XCTAssertFalse(decoder.hasSession)

        let format = try h264Format()
        decoder.updateFormatDescription(format, isKeyframe: false)
        XCTAssertFalse(decoder.hasSession, "a new session waits for a keyframe")

        decoder.updateFormatDescription(format, isKeyframe: true)
        XCTAssertTrue(decoder.hasSession)
        decoder.tearDown()
    }

    /// A format change on a running stream still switches sessions immediately.
    func testFormatChangeWithASessionRecreatesItWithoutWaiting() throws {
        let decoder = VideoDecoder()
        decoder.updateFormatDescription(try h264Format(), isKeyframe: true)
        XCTAssertTrue(decoder.hasSession)

        decoder.updateFormatDescription(try undecodableFormat(), isKeyframe: false)

        XCTAssertFalse(decoder.hasSession)
        XCTAssertEqual(recorder.count(startingWith: creationFailure), 1)
        decoder.tearDown()
    }
}

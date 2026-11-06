@testable import LemurCam
import XCTest

/// Locks how the resampler's input buffer is filled. It is sized in whole frames
/// (`samples / channels`), but the copy used to take every sample, so a stereo L16
/// packet with an odd sample count wrote one Float past the end of the buffer. The
/// copy now stops at the last whole frame.
internal final class AudioDecoderInputBufferTests: XCTestCase {

    /// A large call first grows the reusable buffer, so the odd-count call that follows
    /// writes inside its capacity: a sample copied past the last whole frame shows up as
    /// an overwritten slot instead of corrupting the heap.
    func testOddStereoSampleCountCopiesOnlyWholeFrames() throws {
        let decoder = AudioDecoder(sourceRate: 8000, sourceChannels: 2)
        let large = [Float](repeating: 1, count: 1000)
        _ = try XCTUnwrap(decoder.loadInputBuffer(large[...]))

        let odd = [Float](repeating: 0.5, count: 321)
        let buffer = try XCTUnwrap(decoder.loadInputBuffer(odd[...]))
        let samples = try XCTUnwrap(buffer.floatChannelData)[0]

        XCTAssertEqual(buffer.frameLength, 160, "321 stereo samples hold 160 whole frames")
        XCTAssertEqual(samples[319], 0.5, "the last whole frame must be copied")
        XCTAssertEqual(samples[320], 1, "the trailing half frame must not be copied")
    }

    func testWholeFramesAreCopiedInOrder() throws {
        let decoder = AudioDecoder(sourceRate: 8000, sourceChannels: 2)
        let input: [Float] = [0.1, 0.2, 0.3, 0.4]

        let buffer = try XCTUnwrap(decoder.loadInputBuffer(input[...]))
        let samples = try XCTUnwrap(buffer.floatChannelData)[0]

        XCTAssertEqual(buffer.frameLength, 2)
        XCTAssertEqual(Array(UnsafeBufferPointer(start: samples, count: 4)), input)
    }

    func testLessThanOneFrameLoadsNothing() {
        let decoder = AudioDecoder(sourceRate: 8000, sourceChannels: 2)
        let input: [Float] = [0.5]

        XCTAssertNil(decoder.loadInputBuffer(input[...]))
    }

    /// End to end: an odd stereo packet still resamples and emits its whole frames.
    func testOddStereoPacketStillEmitsAudio() {
        let decoder = AudioDecoder(sourceRate: 8000, sourceChannels: 2)
        let emitted = expectation(description: "PCM emitted")
        emitted.assertForOverFulfill = false
        decoder.onPCM = { _, frames in
            if frames > 0 { emitted.fulfill() }
        }

        let input = (0..<641).map { Float(sin(Double($0) * 0.05)) }
        decoder.resampleAndEmit(input[...])

        wait(for: [emitted], timeout: 1)
    }
}

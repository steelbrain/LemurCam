import AVFAudio
@testable import LemurCam
import os
import XCTest

/// `AVAudioFormat` gives no format for more than two channels without a channel
/// layout, so a camera sending 3.0 to 7.1 AAC or multichannel L16 got no resampler
/// and a silent microphone. Such audio now reaches the stereo output from its first
/// two channels.
internal final class AudioDecoderChannelTests: XCTestCase {
    func testMoreThanTwoChannelsReachTheStereoOutput() throws {
        for channels in [3, 6, 8] {
            let decoder = AudioDecoder(sourceRate: 16_000, sourceChannels: channels)
            let output = StereoCapture()
            decoder.onPCM = { samples, frames in output.append(samples, frames: frames) }
            // 200 ms: 0.5 on the first channel, -0.25 on the second, 0.9 on the rest.
            var input: [Float] = []
            for _ in 0..<3200 {
                input.append(0.5)
                input.append(-0.25)
                input.append(contentsOf: repeatElement(0.9, count: channels - 2))
            }

            decoder.resampleAndEmit(input[...])

            let (left, right) = output.channels
            XCTAssertGreaterThan(left.count, 4800, "\(channels) channels: audio comes out")
            // Past the resampler's start-up ramp, each side carries its own channel.
            let middle = left.count / 2
            XCTAssertEqual(try XCTUnwrap(left[safe: middle]), 0.5, accuracy: 0.02, "\(channels) channels: left")
            XCTAssertEqual(try XCTUnwrap(right[safe: middle]), -0.25, accuracy: 0.02, "\(channels) channels: right")
        }
    }

    func testMonoAndStereoKeepTheirMapping() {
        XCTAssertEqual(AudioDecoder.resamplerChannelMap(sourceChannels: 1), [0, 0])
        XCTAssertEqual(AudioDecoder.resamplerChannelMap(sourceChannels: 2), [])
        XCTAssertEqual(AudioDecoder.resamplerChannelMap(sourceChannels: 6), [0, 1])
        for channels in 1...8 {
            XCTAssertEqual(
                AudioDecoder.resamplerInputFormat(sampleRate: 48_000, channels: channels)?.channelCount,
                AVAudioChannelCount(channels), "\(channels) channels"
            )
        }
    }
}

/// Collects the decoder's interleaved stereo output.
private final class StereoCapture: Sendable {
    private let samples = OSAllocatedUnfairLock<[Float]>(initialState: [])

    var channels: (left: [Float], right: [Float]) {
        let all = samples.withLock { $0 }
        return (
            stride(from: 0, to: all.count, by: 2).map { all[$0] },
            stride(from: 1, to: all.count, by: 2).map { all[$0] }
        )
    }

    func append(_ pointer: UnsafePointer<Float>, frames: Int) {
        let copy = Array(UnsafeBufferPointer(start: pointer, count: frames * 2))
        samples.withLock { $0.append(contentsOf: copy) }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

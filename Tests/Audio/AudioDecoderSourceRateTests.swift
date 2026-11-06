import Foundation
@testable import LemurCam
import os
import XCTest

/// A camera's audio sample rate (the SDP clock rate, or the AAC config) was used
/// unchecked, and the resampler sized its output buffer from it as input frames ×
/// 48000 / rate and kept it: L16 at 16 Hz with a 32,767-sample packet allocated
/// about 786 MB. A rate outside `AudioDecoder.supportedSourceRates` now gets no
/// resampler, so every packet is dropped before any buffer is allocated, and the
/// refusal is logged once per stream.
internal final class AudioDecoderSourceRateTests: XCTestCase {
    private let refusal = "AudioDecoder: camera audio sample rate"
    private let recorder = LogLineRecorder()
    /// The largest L16 packet a camera can send: 32,767 16-bit samples.
    private let largestPacket = [Float](repeating: 0.25, count: 32_767)

    override func setUp() {
        super.setUp()
        recorder.install()
    }

    override func tearDown() {
        recorder.uninstall()
        super.tearDown()
    }

    func testTheRangeKeepsEveryRateCamerasUse() {
        let rates = [7350, 8000, 11_025, 12_000, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000, 88_200, 96_000]
        for rate in rates {
            XCTAssertTrue(AudioDecoder.supportedSourceRates.contains(Double(rate)), "\(rate) Hz")
        }
    }

    func testAnOutOfRangeRateAllocatesAndEmitsNothing() {
        for rate in [1, 16, 3999, 192_001, Double(UInt32.max)] {
            let decoder = AudioDecoder(sourceRate: rate, sourceChannels: 1)
            let emitted = FrameCounter()
            decoder.onPCM = { _, frames in emitted.add(frames) }

            for _ in 0..<3 {
                decoder.resampleAndEmit(largestPacket[...])
            }

            XCTAssertEqual(emitted.total, 0, "\(rate) Hz")
            XCTAssertEqual(decoder.outputBufferFrameCapacity, 0, "\(rate) Hz: no output buffer")
            XCTAssertNil(decoder.loadInputBuffer(largestPacket[...]), "\(rate) Hz: no input buffer")
        }
    }

    func testAnOutOfRangeRateLogsOncePerStream() {
        let decoder = AudioDecoder(sourceRate: 16, sourceChannels: 1)
        for _ in 0..<5 {
            decoder.resampleAndEmit(largestPacket[...])
        }

        XCTAssertEqual(recorder.count(startingWith: refusal), 1)
        XCTAssertEqual(
            AudioDecoder.unsupportedSourceRateMessage(16),
            "camera audio sample rate 16 Hz is outside 4000–192000 Hz; no microphone audio"
        )
    }

    /// An AAC stream at a refused rate gets no AAC decoder either: it would only
    /// decode audio to throw away.
    func testAnOutOfRangeAACRateSetsUpNoAACDecoder() {
        let decoder = AudioDecoder(sourceRate: 16, sourceChannels: 2)
        decoder.setUpAAC(asc: Data([0x11, 0x90]))

        XCTAssertNil(decoder.aacConverter)
        decoder.decodeAAC(Data([0x01, 0x02, 0x03]))
    }

    func testInRangeRatesStillDecode() {
        let cases: [(rate: Double, channels: Int)] = [
            (4000, 1), (8000, 1), (16_000, 1), (44_100, 2), (48_000, 2), (96_000, 2), (192_000, 1)
        ]
        for (rate, channels) in cases {
            let decoder = AudioDecoder(sourceRate: rate, sourceChannels: channels)
            let emitted = FrameCounter()
            decoder.onPCM = { _, frames in emitted.add(frames) }
            // 100 ms of a tone, twice.
            let input = (0..<Int(rate / 10) * channels).map { Float(sin(Double($0) * 0.05)) }

            decoder.resampleAndEmit(input[...])
            decoder.resampleAndEmit(input[...])

            XCTAssertGreaterThan(emitted.total, 4800, "\(rate) Hz: more than 100 ms of 48 kHz output")
            XCTAssertLessThanOrEqual(emitted.total, 9600, "\(rate) Hz: no more than 200 ms of 48 kHz output")
        }
        XCTAssertEqual(recorder.count(startingWith: refusal), 0)
    }

    /// The bottom of the range bounds what one packet can allocate: the largest packet
    /// at 4 kHz needs under 400,000 output frames (about 3 MB), where 16 Hz asked for
    /// about 98 million (786 MB).
    func testTheLargestPacketAtTheLowestRateStaysSmall() {
        let decoder = AudioDecoder(sourceRate: 4000, sourceChannels: 1)
        let emitted = FrameCounter()
        decoder.onPCM = { _, frames in emitted.add(frames) }

        decoder.resampleAndEmit(largestPacket[...])

        XCTAssertGreaterThan(emitted.total, 0)
        XCTAssertLessThanOrEqual(decoder.outputBufferFrameCapacity, 32_767 * 12 + 2048)
    }
}

private final class FrameCounter: Sendable {
    private let frames = OSAllocatedUnfairLock<Int>(initialState: 0)

    var total: Int {
        frames.withLock { $0 }
    }

    func add(_ count: Int) {
        frames.withLock { $0 += count }
    }
}

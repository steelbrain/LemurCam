import AudioToolbox
import Foundation
@testable import LemurCam
import XCTest

/// Locks the dedupe of per-access-unit audio decode failures. A broken AAC stream
/// fails every unit, 15 to 47 a second, and each failure logged a line, flooding
/// the 1000-entry in-app log. A run of identical failures now logs once, as the
/// video decoder's do.
internal final class AudioDecoderErrorLogTests: XCTestCase {
    private let aacFailure = "AudioDecoder: AAC decode failed"
    private let recorder = LogLineRecorder()
    /// Three bytes are no AAC access unit. A fresh decoder takes the first few
    /// silently while it primes, then fails each with `kAudioCodecBadDataError`.
    private let badAccessUnit = Data([0x01, 0x02, 0x03])
    /// Enough bad units to get past the decoder's priming.
    private let unitCount = 30

    override func setUp() {
        super.setUp()
        recorder.install()
    }

    override func tearDown() {
        recorder.uninstall()
        super.tearDown()
    }

    /// A real 48 kHz stereo AAC-LC decoder (AudioSpecificConfig 0x11 0x90).
    private func makeAACDecoder() -> AudioDecoder {
        let decoder = AudioDecoder(sourceRate: 48_000, sourceChannels: 2)
        decoder.setUpAAC(asc: Data([0x11, 0x90]))
        XCTAssertNotNil(decoder.aacConverter, "the AAC decoder must be created")
        return decoder
    }

    func testARunOfFailedAccessUnitsLogsOnce() {
        let decoder = makeAACDecoder()

        for _ in 0..<unitCount {
            decoder.decodeAAC(badAccessUnit)
        }

        XCTAssertEqual(recorder.count(startingWith: aacFailure), 1)
        decoder.tearDown()
    }

    /// Each stream gets its own decoder, so a reconnect logs its first failure again.
    func testEachStreamLogsItsFirstFailure() {
        for _ in 0..<2 {
            let decoder = makeAACDecoder()
            for _ in 0..<unitCount {
                decoder.decodeAAC(badAccessUnit)
            }
            decoder.tearDown()
        }

        XCTAssertEqual(recorder.count(startingWith: aacFailure), 2)
    }

    /// Resample failures are deduplicated by the converter's error code. Without a
    /// usable code they still count as a failure: a zero code would read as success
    /// and never be logged.
    func testResampleFailureStatusUsesTheErrorCode() {
        let paramError = NSError(domain: NSOSStatusErrorDomain, code: Int(kAudio_ParamError))
        XCTAssertEqual(AudioDecoder.resampleFailureStatus(paramError), kAudio_ParamError)

        XCTAssertEqual(AudioDecoder.resampleFailureStatus(nil), kAudioConverterErr_UnspecifiedError)
        let zeroCode = NSError(domain: NSOSStatusErrorDomain, code: 0)
        XCTAssertEqual(AudioDecoder.resampleFailureStatus(zeroCode), kAudioConverterErr_UnspecifiedError)
    }
}

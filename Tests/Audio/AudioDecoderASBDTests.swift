import AudioToolbox
@testable import LemurCam
import XCTest

/// Locks the two `AudioStreamBasicDescription` builders that frame the AAC decode
/// path: the canonical Float32 PCM *output* format the converter targets, and the
/// AAC *input* format derived from the stream's ESDS magic cookie via CoreAudio's
/// FormatInfo query. The live AAC decode loop needs a real stream and is covered
/// on-device, but these format builders are pure (no audio hardware) and define the
/// contract `AudioConverterNew` is handed — a wrong flag, bit depth, or a cookie
/// parse that silently produces an all-zero format would corrupt or kill mic audio.
internal final class AudioDecoderASBDTests: XCTestCase {

    // MARK: - pcmOutputASBD (canonical interleaved Float32 PCM)

    func testPCMOutputASBDStereoLayout() {
        let asbd = AudioDecoder.pcmOutputASBD(rate: 48_000, channels: 2)
        XCTAssertEqual(asbd.mFormatID, kAudioFormatLinearPCM)
        XCTAssertEqual(asbd.mSampleRate, 48_000)
        XCTAssertEqual(asbd.mChannelsPerFrame, 2)
        XCTAssertEqual(asbd.mBitsPerChannel, 32)
        XCTAssertEqual(asbd.mFramesPerPacket, 1)
        // Interleaved Float32: 4 bytes per sample × channels, and one frame per packet.
        XCTAssertEqual(asbd.mBytesPerFrame, 8)
        XCTAssertEqual(asbd.mBytesPerPacket, 8)
    }

    func testPCMOutputASBDMonoBytesTrackChannelCount() {
        let asbd = AudioDecoder.pcmOutputASBD(rate: 8000, channels: 1)
        XCTAssertEqual(asbd.mChannelsPerFrame, 1)
        XCTAssertEqual(asbd.mSampleRate, 8000)
        XCTAssertEqual(asbd.mBytesPerFrame, 4)
        XCTAssertEqual(asbd.mBytesPerPacket, 4)
    }

    /// The format must be flagged as packed float; either flag missing would make the
    /// converter interpret the buffer as a different (e.g. integer) sample layout.
    func testPCMOutputASBDIsPackedFloat() {
        let asbd = AudioDecoder.pcmOutputASBD(rate: 48_000, channels: 2)
        XCTAssertEqual(asbd.mFormatFlags & kAudioFormatFlagIsFloat, kAudioFormatFlagIsFloat)
        XCTAssertEqual(asbd.mFormatFlags & kAudioFormatFlagIsPacked, kAudioFormatFlagIsPacked)
    }

    // MARK: - aacInputASBD (derived from the ESDS magic cookie)

    /// A valid ESDS cookie wrapping the canonical 48 kHz stereo AAC-LC config
    /// (ASC 0x11 0x90) must yield an AAC ASBD whose rate and channel count come from
    /// the cookie, not a hard-coded guess.
    func testAACInputASBDReadsSampleRateAndChannelsFromCookie() throws {
        let cookie = AudioDecoder.aacMagicCookie(from: Data([0x11, 0x90]))
        let asbd = try XCTUnwrap(AudioDecoder.aacInputASBD(cookie: cookie))
        XCTAssertEqual(asbd.mFormatID, kAudioFormatMPEG4AAC)
        XCTAssertEqual(asbd.mSampleRate, 48_000)
        XCTAssertEqual(asbd.mChannelsPerFrame, 2)
    }

    /// A different ASC (44.1 kHz mono AAC-LC, 0x12 0x08) proves the builder parses the
    /// cookie rather than returning a fixed format.
    func testAACInputASBDTracksADifferentConfig() throws {
        let cookie = AudioDecoder.aacMagicCookie(from: Data([0x12, 0x08]))
        let asbd = try XCTUnwrap(AudioDecoder.aacInputASBD(cookie: cookie))
        XCTAssertEqual(asbd.mSampleRate, 44_100)
        XCTAssertEqual(asbd.mChannelsPerFrame, 1)
    }

    /// A cookie CoreAudio cannot parse returns nil so setup fails loudly, instead of
    /// feeding an all-zero (rate 0 / channels 0) format into `AudioConverterNew`.
    func testAACInputASBDReturnsNilForUnparseableCookie() {
        XCTAssertNil(AudioDecoder.aacInputASBD(cookie: Data([0x00, 0x00, 0x00])))
        XCTAssertNil(AudioDecoder.aacInputASBD(cookie: Data()))
    }

    // MARK: - aacSourceGeometry (ASC is authoritative over SDP)

    /// When the ASC and SDP disagree, the decoder must take rate/channels from the ASC.
    /// ASC 0x11 0x90 = 48 kHz stereo; the SDP here lies (8 kHz mono). Before the fix the
    /// decoder built its output format and resampler from the SDP, so the AAC converter's
    /// output geometry contradicted the scratch sizing and downstream resampler.
    func testAACSourceGeometryPrefersASCOverSDP() {
        let geometry = AudioDecoder.aacSourceGeometry(
            asc: Data([0x11, 0x90]), sdpRate: 8000, sdpChannels: 1
        )
        XCTAssertEqual(geometry.rate, 48_000)
        XCTAssertEqual(geometry.channels, 2)
    }

    /// A different ASC (44.1 kHz mono, 0x12 0x08) wins over a stereo SDP — proving the
    /// override reads the config rather than clamping to a fixed layout.
    func testAACSourceGeometryTracksMonoASCOverStereoSDP() {
        let geometry = AudioDecoder.aacSourceGeometry(
            asc: Data([0x12, 0x08]), sdpRate: 48_000, sdpChannels: 2
        )
        XCTAssertEqual(geometry.rate, 44_100)
        XCTAssertEqual(geometry.channels, 1)
    }

    func testAACSourceGeometryFallsBackToSDPWhenASCMissing() {
        let geometry = AudioDecoder.aacSourceGeometry(
            asc: Data(), sdpRate: 16_000, sdpChannels: 2
        )
        XCTAssertEqual(geometry.rate, 16_000)
        XCTAssertEqual(geometry.channels, 2)
    }

    func testAACSourceGeometryFallsBackToSDPWhenASCUnparseable() {
        let geometry = AudioDecoder.aacSourceGeometry(
            asc: Data([0x00, 0x00, 0x00]), sdpRate: 44_100, sdpChannels: 1
        )
        XCTAssertEqual(geometry.rate, 44_100)
        XCTAssertEqual(geometry.channels, 1)
    }
}

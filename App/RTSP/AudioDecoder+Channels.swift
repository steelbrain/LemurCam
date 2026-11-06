import AVFAudio

internal extension AudioDecoder {
    /// The interleaved Float32 format the resampler reads camera audio with `channels`
    /// channels in. `AVAudioFormat(commonFormat:sampleRate:channels:interleaved:)`
    /// returns nil for more than two channels without a channel layout, so a camera
    /// sending 3.0 to 7.1 AAC (which IPCamKit accepts) or multichannel L16 got no
    /// resampler, and the microphone stayed silent while the video played. Those get a
    /// layout of discrete channels in the order the stream carries them.
    static func resamplerInputFormat(sampleRate: Double, channels: Int) -> AVAudioFormat? {
        guard channels > 2 else {
            return AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                channels: AVAudioChannelCount(max(channels, 1)), interleaved: true
            )
        }
        guard channels <= Int(UInt16.max),
              let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels))
        else { return nil }
        return AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, interleaved: true, channelLayout: layout
        )
    }

    /// Which source channels feed the stereo output's left and right: mono into both,
    /// stereo as it is (empty: no map), and from more channels the first two, which
    /// carry front audio in AAC's and L16's channel orders: center and left for AAC;
    /// for L16 (RFC 3551), left and right with 3 channels, left and center with 4,
    /// left and left center with 6. A discrete layout gives the converter nothing to
    /// downmix by.
    static func resamplerChannelMap(sourceChannels: Int) -> [NSNumber] {
        switch sourceChannels {
        case ...1: return [0, 0]
        case 2: return []
        default: return [0, 1]
        }
    }
}

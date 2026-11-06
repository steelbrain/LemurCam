import Foundation

internal extension AudioDecoder {
    /// Source sample rates the decoder converts. G.711 runs at 8 kHz, AAC's standard
    /// rates span 7.35 to 96 kHz, and L16 cameras use rates in that span. The rate
    /// comes from the camera (the SDP clock rate, or the AAC config), and the
    /// resampler's output buffer is sized from it as input frames × 48000 / rate, so
    /// a rate of a few hertz asked for hundreds of megabytes for one packet. A rate
    /// outside this range gets no microphone audio; the video still plays.
    static let supportedSourceRates: ClosedRange<Double> = 4000...192_000

    /// What the log says about a source rate outside `supportedSourceRates`.
    static func unsupportedSourceRateMessage(_ rate: Double) -> String {
        let lower = Int(supportedSourceRates.lowerBound)
        let upper = Int(supportedSourceRates.upperBound)
        return "camera audio sample rate \(String(format: "%g", rate)) Hz is outside "
            + "\(lower)–\(upper) Hz; no microphone audio"
    }
}

import CoreMedia
import CoreVideo

/// One format the virtual camera can run in: a resolution at a frame rate.
internal struct StreamFormatSelection: Equatable, Sendable {
    var resolution: LemurCamConfig.Resolution
    var frameRate: LemurCamConfig.FrameRate

    /// The index of this format's resolution in the streams' `formats`.
    var formatIndex: Int {
        StreamFormatTable.formatIndex(of: resolution)
    }

    /// The time between frames at this format's frame rate.
    var frameDuration: CMTime {
        StreamFormatTable.frameDuration(of: frameRate)
    }

    /// `frameDuration` in nanoseconds, for pacing against the host clock.
    var frameDurationNanoseconds: UInt64 {
        UInt64(NSEC_PER_SEC) / UInt64(frameRate.rawValue)
    }
}

/// The formats the camera extension advertises on its source and sink streams,
/// and the mapping between CMIO's terms for them (a format index, a frame
/// duration) and the app's settings. Every resolution is offered at every frame
/// rate, in one pixel format. Lives in `Shared/` so the extension, the app and the
/// tests read one table.
internal enum StreamFormatTable {
    /// Every advertised resolution, in format-index order: a stream's
    /// `formats[i]` is `resolutions[i]`.
    static let resolutions = LemurCamConfig.Resolution.allCases

    /// The pixel format of every advertised format, and of every frame the camera
    /// sends: 8-bit 4:2:0 YCbCr, video range (NV12), what the app's decoder emits.
    static let pixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

    /// The frame durations every format allows, one per frame rate, shortest
    /// (fastest) first. The header defines a list like this as discrete: no
    /// duration between them is valid (CMIOExtensionProperties.h, `validFrameDurations`).
    static let validFrameDurations: [CMTime] = LemurCamConfig.FrameRate.allCases
        .sorted { $0.rawValue > $1.rawValue }
        .map(frameDuration(of:))

    /// The fastest frame rate any format allows.
    static let fastestFrameRate = LemurCamConfig.FrameRate.allCases.max { $0.rawValue < $1.rawValue }
        ?? LemurCamConfig.defaultFrameRate

    /// The shortest frame duration (the fastest rate).
    static var minFrameDuration: CMTime {
        validFrameDurations.first ?? frameDuration(of: LemurCamConfig.defaultFrameRate)
    }

    /// The longest frame duration (the slowest rate).
    static var maxFrameDuration: CMTime {
        validFrameDurations.last ?? frameDuration(of: LemurCamConfig.defaultFrameRate)
    }

    static func frameDuration(of frameRate: LemurCamConfig.FrameRate) -> CMTime {
        CMTime(value: 1, timescale: CMTimeScale(frameRate.rawValue))
    }

    static func formatIndex(of resolution: LemurCamConfig.Resolution) -> Int {
        resolutions.firstIndex(of: resolution) ?? 0
    }

    /// The resolution of `formats[index]`, or nil when no format has that index.
    static func resolution(atFormatIndex index: Int) -> LemurCamConfig.Resolution? {
        resolutions.indices.contains(index) ? resolutions[index] : nil
    }

    /// The frame rate whose duration `duration` is, or nil when it is none of them.
    /// A client's duration may come in another timescale, or rounded from a rate
    /// (1/29.97 s for 30 fps), so it matches within `Tuning.frameDurationMatchTolerance`
    /// of a valid one. Zero, negative, invalid and indefinite durations match none.
    static func frameRate(forFrameDuration duration: CMTime) -> LemurCamConfig.FrameRate? {
        guard duration.isNumeric else { return nil }
        let seconds = duration.seconds
        guard seconds.isFinite, seconds > 0 else { return nil }
        return LemurCamConfig.FrameRate.allCases.first { rate in
            let expected = 1.0 / Double(rate.rawValue)
            return abs(seconds - expected) <= expected * Tuning.frameDurationMatchTolerance
        }
    }

    /// The index in `dimensions` (a stream's formats, as the app reads them from
    /// CMIO) of the one at `resolution`'s size, or nil when none is.
    static func index(of resolution: LemurCamConfig.Resolution, among dimensions: [CMVideoDimensions]) -> Int? {
        dimensions.firstIndex { $0.width == resolution.width && $0.height == resolution.height }
    }

    /// Whether a frame of this size and pixel format can go to a consumer of
    /// `resolution` as it is, or must be scaled to it first.
    static func passesThrough(
        width: Int, height: Int, pixelFormat framePixelFormat: OSType,
        to resolution: LemurCamConfig.Resolution
    ) -> Bool {
        width == Int(resolution.width) && height == Int(resolution.height) && framePixelFormat == pixelFormat
    }
}

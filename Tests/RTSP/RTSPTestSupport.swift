import Foundation
@testable import LemurCam
import os

/// H.264 parameter sets for a 64x64 Constrained Baseline stream, taken from an
/// x264 encode. Unlike the hand-written minimal SPS in `NALProcessorTests`,
/// CoreMedia accepts these, so they build a real format description.
internal enum H264TestStream {
    static let sps = Data([
        0x67, 0x42, 0xC0, 0x0A, 0xDC, 0x42, 0x6C, 0x04, 0x40, 0x00, 0x00,
        0x03, 0x00, 0x40, 0x00, 0x00, 0x03, 0x00, 0x83, 0xC4, 0x89, 0xE0
    ])
    static let pps = Data([0x68, 0xCE, 0x0F, 0x2C, 0x80])

    /// Bytes CoreMedia rejects as an SPS (a truncated header).
    static let invalidSPS = Data([0x67, 0xFF])

    /// An IDR slice NAL header (type 5) with a token payload.
    static func keyframe(loss: UInt16 = 0) -> VideoFrameInput {
        VideoFrameInput(nalus: [Data([0x65, 0x88, 0x84])], isKeyframe: true, loss: loss)
    }

    /// A non-IDR slice NAL header (type 1) with a token payload.
    static func deltaFrame(loss: UInt16 = 0) -> VideoFrameInput {
        VideoFrameInput(nalus: [Data([0x41, 0x9A, 0x02])], isKeyframe: false, loss: loss)
    }
}

/// Captures `DualLogger` lines through its process-wide `onEmit` sink. Install it in
/// `setUp` and call `uninstall()` in `tearDown`, which restores the previous sink so
/// a running host app keeps its log view.
internal final class LogLineRecorder: Sendable {
    private let lines = OSAllocatedUnfairLock<[String]>(initialState: [])
    private let previous = OSAllocatedUnfairLock<(@Sendable (String, String, String) -> Void)?>(
        initialState: nil
    )

    func install() {
        let saved = DualLogger.onEmit
        previous.withLock { $0 = saved }
        DualLogger.onEmit = { [lines] _, _, message in
            lines.withLock { $0.append(message) }
        }
    }

    func uninstall() {
        DualLogger.onEmit = previous.withLock { $0 }
    }

    /// The number of captured lines that start with `prefix`.
    func count(startingWith prefix: String) -> Int {
        lines.withLock { $0.filter { $0.hasPrefix(prefix) }.count }
    }
}

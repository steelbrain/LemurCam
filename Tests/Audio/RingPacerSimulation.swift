// This import brings in the app's bridging header (the C ring API), a use the analyzer misses.
// swiftlint:disable:next unused_import
@testable import LemurCam

/// Producer/consumer simulation of the paced ring in frame time, shared by the pacer
/// test classes. Frames carry consecutive sequence numbers (from 1, so 0 means
/// underrun silence); the consumer counts every jump in the sequence it plays, which
/// is exactly a trim, and every run of short reads, which is an audible gap.
internal final class RingPacerSimulation {
    private typealias Support = RingTestSupport

    let ring = RingTestSupport.makeRing()
    var pacer = LemurAudioRingPacer()
    private(set) var nextSequence = 1
    private(set) var lastPlayed = 0
    private(set) var skips = 0
    private(set) var underrunFrames = 0
    private(set) var gaps = 0
    /// Highest backlog left after a read since `resetMaxBacklog`.
    private(set) var maxBacklog = 0
    private var inGap = false
    /// False plays every buffered frame (`lemur_ring_read`), as a baseline.
    private let paced: Bool

    init(paced: Bool = true) {
        self.paced = paced
        lemur_ring_init(ring)
        lemur_ring_pacer_reset(&pacer)
    }

    deinit { Support.release(ring) }

    var backlog: Int { Int(lemur_ring_filled(ring)) }

    func produce(_ frames: Int) {
        Support.writeSequence(ring, from: nextSequence, frames: frames)
        nextSequence += frames
    }

    func consume(_ frames: Int) {
        var dst = [Float](repeating: .nan, count: frames * Support.channels)
        let copied = dst.withUnsafeMutableBufferPointer { buffer in
            paced
                ? lemur_ring_read_paced(ring, &pacer, buffer.baseAddress, UInt32(frames))
                : lemur_ring_read(ring, buffer.baseAddress, UInt32(frames))
        }
        underrunFrames += frames - Int(copied)
        if Int(copied) < frames {
            if !inGap { gaps += 1 }
            inGap = true
        } else {
            inGap = false
        }
        for frame in 0..<Int(copied) {
            let played = Int(dst[frame * Support.channels])
            if lastPlayed != 0, played != lastPlayed + 1 { skips += 1 }
            lastPlayed = played
        }
        maxBacklog = max(maxBacklog, backlog)
    }

    func resetMaxBacklog() {
        maxBacklog = 0
    }

    /// Run `duration` frames of real time: the consumer reads `readChunk` frames
    /// per IO cycle; the producer delivers `producerChunk` frames whenever a whole
    /// chunk of real time has elapsed (unless `producing` says otherwise).
    func run(
        duration: Int, readChunk: Int = 512, producerChunk: Int = 960,
        producing: (Int) -> Bool = { _ in true }
    ) {
        var produced = 0
        var time = 0
        while time < duration {
            time += readChunk
            while produced + producerChunk <= time {
                produced += producerChunk
                if producing(produced) { produce(producerChunk) }
            }
            consume(readChunk)
        }
    }

    /// Run `duration` frames of real time over a network that stalls: while
    /// `isStalled(time)` the producer's 960-frame packets are held back, and when the
    /// stall ends they all arrive at once (what an RTSP stream over TCP does).
    func runWithStalls(duration: Int, isStalled: (Int) -> Bool) {
        var produced = 0
        var held = 0
        var time = 0
        while time < duration {
            time += 512
            while produced + 960 <= time {
                produced += 960
                held += 960
            }
            if held > 0, !isStalled(time) {
                produce(held)
                held = 0
            }
            consume(512)
        }
    }
}

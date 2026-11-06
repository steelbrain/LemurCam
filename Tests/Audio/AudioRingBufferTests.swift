import Darwin
@testable import LemurCam
import XCTest

/// Exercises the app-side producer against a real POSIX shm region under a private,
/// per-test name (never `LEMUR_AUDIO_SHM_NAME`, which a live driver may map). A second
/// mapping of the same region stands in for the driver, so the tests observe exactly
/// what the consumer would see.
internal final class AudioRingBufferTests: XCTestCase {
    private typealias Support = RingTestSupport

    /// The consumer's view of a region: a separate mapping of the same shm object.
    private final class ConsumerMapping {
        let ring: UnsafeMutablePointer<LemurAudioRing>
        private let descriptor: Int32
        private let size = MemoryLayout<LemurAudioRing>.size

        init?(name: String) {
            descriptor = lemur_shm_open_create(name)
            guard descriptor >= 0 else { return nil }
            let base = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_SHARED, descriptor, 0)
            guard let base, base != MAP_FAILED else {
                close(descriptor)
                return nil
            }
            ring = base.bindMemory(to: LemurAudioRing.self, capacity: 1)
        }

        deinit {
            munmap(UnsafeMutableRawPointer(ring), size)
            close(descriptor)
        }
    }

    private func uniqueName() -> String {
        "/lemur.t.\(getpid()).\(UInt16.random(in: 0...UInt16.max))"
    }

    private func write(_ buffer: AudioRingBuffer, from first: Int, frames: Int) {
        let samples = (first..<(first + frames)).flatMap { [Float($0), Float($0)] }
        samples.withUnsafeBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return }
            buffer.write(base, frames: frames)
        }
    }

    private func sequence(from first: Int, frames: Int) -> [Float] {
        (first..<(first + frames)).flatMap { [Float($0), Float($0)] }
    }

    /// Open a producer plus a consumer mapping on a fresh private region, run `body`,
    /// then unlink the region.
    private func withRegion(
        _ body: (_ name: String, _ buffer: AudioRingBuffer, _ consumer: ConsumerMapping) throws -> Void
    ) rethrows {
        let name = uniqueName()
        defer { shm_unlink(name) }
        let buffer = AudioRingBuffer(name: name)
        XCTAssertTrue(buffer.open())
        guard let consumer = ConsumerMapping(name: name) else {
            XCTFail("could not map the test region")
            return
        }
        try body(name, buffer, consumer)
    }

    func testOpenCreatesInitialisedIdleRing() {
        withRegion { _, buffer, consumer in
            XCTAssertTrue(buffer.isOpen)
            XCTAssertFalse(buffer.isProducing)
            XCTAssertNotEqual(lemur_ring_ready(consumer.ring), 0)
            XCTAssertEqual(lemur_ring_filled(consumer.ring), 0)
        }
    }

    func testWriteWhileNotProducingKeepsRingDrained() {
        withRegion { _, buffer, consumer in
            write(buffer, from: 0, frames: 64)
            XCTAssertEqual(lemur_ring_filled(consumer.ring), 0, "idle writes must not queue audio")

            buffer.beginProducing()
            write(buffer, from: 0, frames: 64)
            XCTAssertEqual(lemur_ring_filled(consumer.ring), 64)

            // Consumer goes away mid-session: the leftover must be dropped by the next
            // idle write so a later consumer doesn't start 64 frames behind.
            buffer.endProducing()
            write(buffer, from: 64, frames: 16)
            XCTAssertEqual(lemur_ring_filled(consumer.ring), 0)
            XCTAssertEqual(consumer.ring.pointee.writeIndex, consumer.ring.pointee.readIndex)
        }
    }

    func testFirstWriteAfterProductionRestartsDropsBacklog() {
        withRegion { _, buffer, consumer in
            buffer.beginProducing()
            write(buffer, from: 0, frames: 100)
            buffer.endProducing()
            buffer.beginProducing() // restarted before any idle write drained the ring

            write(buffer, from: 1000, frames: 10)
            XCTAssertEqual(lemur_ring_filled(consumer.ring), 10, "the 100-frame backlog is dropped once")
            let (copied, samples) = Support.read(consumer.ring, frames: 10)
            XCTAssertEqual(copied, 10)
            XCTAssertEqual(samples, sequence(from: 1000, frames: 10))

            write(buffer, from: 1010, frames: 5)
            XCTAssertEqual(lemur_ring_filled(consumer.ring), 5, "later writes append normally")
        }
    }

    func testReopeningExistingRegionKeepsRingAndClearsStaleProducingFlag() throws {
        let name = uniqueName()
        defer { shm_unlink(name) }
        var first: AudioRingBuffer? = AudioRingBuffer(name: name)
        XCTAssertEqual(first?.open(), true)
        first?.beginProducing()
        write(try XCTUnwrap(first), from: 0, frames: 50)
        let consumer = try XCTUnwrap(ConsumerMapping(name: name), "could not map region")
        XCTAssertEqual(Support.read(consumer.ring, frames: 20).copied, 20)
        first = nil // the app quits (or crashes) while still "producing"
        XCTAssertNotEqual(lemur_ring_is_producing(consumer.ring), 0)

        let second = AudioRingBuffer(name: name)
        XCTAssertTrue(second.open())
        XCTAssertFalse(second.isProducing, "a new app instance starts idle")
        XCTAssertEqual(lemur_ring_is_producing(consumer.ring), 0)
        XCTAssertEqual(consumer.ring.pointee.readIndex, 20, "a live ring is not re-initialised under the driver")
        XCTAssertEqual(consumer.ring.pointee.writeIndex, 50)

        write(second, from: 0, frames: 8)
        XCTAssertEqual(lemur_ring_filled(consumer.ring), 0, "the stale backlog is dropped, not replayed")
    }

    func testReopeningRegionWithForeignLayoutReinitialisesIt() {
        withRegion { name, buffer, consumer in
            buffer.beginProducing()
            write(buffer, from: 0, frames: 32)
            consumer.ring.pointee.magic = 0xDEAD_BEEF

            let reopened = AudioRingBuffer(name: name)
            XCTAssertTrue(reopened.open())
            XCTAssertNotEqual(lemur_ring_ready(consumer.ring), 0)
            XCTAssertEqual(consumer.ring.pointee.writeIndex, 0)
            XCTAssertEqual(consumer.ring.pointee.readIndex, 0)
        }
    }

    func testHostileHeaderDoesNotDerailProducer() {
        withRegion { _, buffer, consumer in
            buffer.beginProducing()
            write(buffer, from: 0, frames: 4)
            // The other side rewrites the header and indices behind our back.
            consumer.ring.pointee.capacityFrames = 0
            consumer.ring.pointee.channels = 0
            consumer.ring.pointee.readIndex = 0x8000_0000 // distance from writeIndex is far past capacity
            consumer.ring.pointee.writeIndex = 5

            write(buffer, from: 500, frames: 64)
            let (copied, samples) = Support.read(consumer.ring, frames: 64)
            XCTAssertEqual(copied, 64)
            XCTAssertEqual(samples, sequence(from: 500, frames: 64), "only the fresh frames are readable")
        }
    }
}

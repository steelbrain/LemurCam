import Darwin
import Foundation
import os
import OSLog

/// App-side producer over the shared-memory ring the AudioServerPlugIn consumes.
/// Creates and maps the POSIX shm region, initialises the `LemurAudioRing`, and
/// writes interleaved 48 kHz Float32 stereo PCM. The region persists (the driver
/// inside coreaudiod maps the same name); only one producer thread may write.
internal final class AudioRingBuffer: Sendable {
    private struct State: Sendable {
        var ringAddress: UInt?
        var fileDescriptor: Int32 = -1
        /// Producer-thread-only: the `producing` flag seen on the previous `write`, so
        /// the first write after production (re)starts drops any backlog exactly once.
        var wasProducing = false
    }

    private let log = Logger(subsystem: "cam.lemur.app", category: "audio-ring")
    private let mapSize = MemoryLayout<LemurAudioRing>.size
    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    var isOpen: Bool {
        state.withLock { $0.ringAddress != nil }
    }

    deinit {
        closeRegion()
    }

    /// Map (creating if necessary) and initialise the shared region. Idempotent.
    @discardableResult
    func open() -> Bool {
        guard !isOpen else { return true }
        // The shim creates + sizes the region once and chmods it so the driver in
        // coreaudiod (a different uid) can map it read-write; see the bridging header.
        let descriptor = lemur_shm_open_create(LEMUR_AUDIO_SHM_NAME)
        guard descriptor >= 0 else {
            log.error("shm_open/ftruncate failed: \(errno)")
            return false
        }
        let mapped = mmap(nil, mapSize, PROT_READ | PROT_WRITE, MAP_SHARED, descriptor, 0)
        guard let base = mapped, base != MAP_FAILED else {
            log.error("mmap failed: \(errno)")
            close(descriptor)
            return false
        }
        let ringPointer = base.bindMemory(to: LemurAudioRing.self, capacity: 1)
        // Initialise only if the region is not already a valid ring, so we don't
        // stomp a region a running driver is reading.
        if lemur_ring_ready(ringPointer) == 0 {
            lemur_ring_init(ringPointer)
        }
        let ringAddress = UInt(bitPattern: ringPointer)

        let installed = state.withLock { state in
            guard state.ringAddress == nil else { return false }
            state.ringAddress = ringAddress
            state.fileDescriptor = descriptor
            state.wasProducing = false
            return true
        }

        if installed {
            log.info("audio ring mapped (\(self.mapSize) bytes)")
        } else {
            munmap(UnsafeMutableRawPointer(ringPointer), mapSize)
            close(descriptor)
        }
        return installed
    }

    /// Mark production active. Safe to call from any thread: it only flips the
    /// `producing` flag. The backlog drop happens in `write()` on the producer
    /// thread, so the producer-owned `writeIndex` is never mutated off that thread.
    func beginProducing() {
        state.withLock {
            guard let address = $0.ringAddress else { return }
            Self.ringPointer(from: address).pointee.producing = 1
        }
    }

    /// Stop producing; the driver will read silence (underrun) until resumed.
    func endProducing() {
        state.withLock {
            guard let address = $0.ringAddress else { return }
            Self.ringPointer(from: address).pointee.producing = 0
        }
    }

    /// Append `frames` interleaved Float32 stereo frames. Single producer only:
    /// this method is the sole writer of `writeIndex`. While not producing it keeps
    /// the ring drained so a later consumer starts on fresh audio, not stale backlog.
    func write(_ samples: UnsafePointer<Float>, frames: Int) {
        guard frames > 0 else { return }
        let sampleAddress = UInt(bitPattern: samples)

        state.withLock {
            guard let address = $0.ringAddress,
                  let inputSamples = UnsafePointer<Float>(bitPattern: sampleAddress) else { return }

            let ring = Self.ringPointer(from: address)
            guard ring.pointee.producing != 0 else {
                ring.pointee.writeIndex = ring.pointee.readIndex
                $0.wasProducing = false
                return
            }
            if !$0.wasProducing {
                ring.pointee.writeIndex = ring.pointee.readIndex
                $0.wasProducing = true
            }
            lemur_ring_write(ring, inputSamples, UInt32(frames), mach_absolute_time())
        }
    }

    private static func ringPointer(from address: UInt) -> UnsafeMutablePointer<LemurAudioRing> {
        guard let rawPointer = UnsafeMutableRawPointer(bitPattern: address) else {
            preconditionFailure("Invalid audio ring pointer")
        }
        return rawPointer.bindMemory(to: LemurAudioRing.self, capacity: 1)
    }

    private func closeRegion() {
        let previous = state.withLock { state in
            let previous = (address: state.ringAddress, fileDescriptor: state.fileDescriptor)
            state.ringAddress = nil
            state.fileDescriptor = -1
            state.wasProducing = false
            return previous
        }

        if let address = previous.address {
            let ring = Self.ringPointer(from: address)
            munmap(UnsafeMutableRawPointer(ring), mapSize)
        }
        if previous.fileDescriptor >= 0 {
            close(previous.fileDescriptor)
        }
    }
}

import Darwin
import os

/// App-side producer over the shared-memory ring the AudioServerPlugIn consumes.
/// Creates and maps the POSIX shm region, initialises the `LemurAudioRing`, and
/// writes interleaved 48 kHz Float32 stereo PCM. The region persists (the driver
/// inside coreaudiod maps the same name); only one producer thread may write.
/// Every ring access goes through the C helpers in `LemurAudioShared.h`, which
/// never trust the shared header or indices for memory safety.
internal final class AudioRingBuffer: Sendable {
    private struct State: Sendable {
        var ringAddress: UInt?
        var fileDescriptor: Int32 = -1
        /// Set when production (re)starts, cleared by the first `write` after it, so
        /// that write drops any backlog exactly once. Tracked here rather than inferred
        /// from what `write` last saw, so a stop/start with no write in between still
        /// drops the old backlog.
        var discardOnNextWrite = true
    }

    private let log = Logger(subsystem: "cam.lemur.app", category: "audio-ring")
    private let mapSize = MemoryLayout<LemurAudioRing>.size
    private let name: String
    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    var isOpen: Bool {
        state.withLock { $0.ringAddress != nil }
    }

    /// Whether the ring's `producing` flag is set. False while not open.
    var isProducing: Bool {
        state.withLock { state in
            guard let address = state.ringAddress else { return false }
            return lemur_ring_is_producing(Self.ringPointer(from: address)) != 0
        }
    }

    /// `name` is the POSIX shm name; tests pass a private one so they never touch the
    /// region a live driver maps.
    init(name: String = LEMUR_AUDIO_SHM_NAME) {
        self.name = name
    }

    deinit {
        closeRegion()
    }

    /// Map (creating if necessary) and initialise the shared region. Idempotent.
    /// Refuses (logs, maps nothing) a region owned by another user or of the wrong
    /// size: anyone can create the name first, and mapping a short object would
    /// fault past its end.
    @discardableResult
    func open() -> Bool {
        guard !isOpen else { return true }
        // The shim creates + sizes the region once with mode 0666 so the driver in
        // coreaudiod (a different uid) can map it read-write; see the bridging header.
        let descriptor = lemur_shm_open_create(name)
        guard descriptor >= 0 else {
            log.error("shm_open/ftruncate failed: \(errno)")
            return false
        }
        guard regionIsUsable(descriptor) else {
            close(descriptor)
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
        // A region reused from an earlier app run can still say "producing" (the
        // flag is only cleared when a consumer stops). This instance has not been
        // told about any consumer yet, so it starts idle and keeps the ring drained.
        lemur_ring_set_producing(ringPointer, 0)
        let ringAddress = UInt(bitPattern: ringPointer)

        let installed = state.withLock { state in
            guard state.ringAddress == nil else { return false }
            state.ringAddress = ringAddress
            state.fileDescriptor = descriptor
            state.discardOnNextWrite = true
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

    /// Mark production active. Safe to call from any thread: it flips the `producing`
    /// flag and, on an idle-to-producing transition, arms a one-time backlog drop. The
    /// drop itself happens in `write()` on the producer thread, so the producer-owned
    /// `writeIndex` is never mutated off that thread.
    func beginProducing() {
        state.withLock {
            guard let address = $0.ringAddress else { return }
            let ring = Self.ringPointer(from: address)
            if lemur_ring_is_producing(ring) == 0 {
                $0.discardOnNextWrite = true
            }
            lemur_ring_set_producing(ring, 1)
        }
    }

    /// Stop producing; the driver will read silence (underrun) until resumed.
    func endProducing() {
        state.withLock {
            guard let address = $0.ringAddress else { return }
            lemur_ring_set_producing(Self.ringPointer(from: address), 0)
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
            guard lemur_ring_is_producing(ring) != 0 else {
                lemur_ring_discard(ring)
                return
            }
            if $0.discardOnNextWrite {
                lemur_ring_discard(ring)
                $0.discardOnNextWrite = false
            }
            lemur_ring_write(ring, inputSamples, UInt32(clamping: frames), mach_absolute_time())
        }
    }

    /// `fstat` the opened region and apply `lemur_shm_check_stat`. Logs why a region
    /// is refused; a region the driver cannot open is still used (after one repair
    /// attempt) because that only silences the mic.
    private func regionIsUsable(_ descriptor: Int32) -> Bool {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            log.error("fstat of audio ring failed: \(errno)")
            return false
        }
        var verdict = lemur_shm_check_stat(&info, geteuid(), mapSize)
        if verdict == LEMUR_SHM_REGION_DRIVER_CANNOT_OPEN {
            // Some systems may honour fchmod on shm; macOS 27 rejects it (EINVAL).
            let chmodResult = fchmod(descriptor, 0o666)
            let chmodErrno = chmodResult == 0 ? 0 : errno
            if fstat(descriptor, &info) == 0 {
                verdict = lemur_shm_check_stat(&info, geteuid(), mapSize)
            }
            if verdict == LEMUR_SHM_REGION_DRIVER_CANNOT_OPEN {
                let mode = String(info.st_mode & 0o777, radix: 8)
                log.error(
                    "audio ring mode \(mode, privacy: .public) blocks the driver (fchmod errno \(chmodErrno))"
                )
                return true
            }
        }
        switch verdict {
        case LEMUR_SHM_REGION_OK:
            return true
        case LEMUR_SHM_REGION_FOREIGN_OWNER:
            log.error("refusing audio ring owned by uid \(info.st_uid), not \(geteuid())")
        case LEMUR_SHM_REGION_BAD_SIZE:
            log.error("refusing audio ring of \(info.st_size) bytes (ring needs \(self.mapSize))")
        default:
            log.error("refusing audio ring (check \(verdict))")
        }
        return false
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

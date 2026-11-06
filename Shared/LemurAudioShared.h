//
//  LemurAudioShared.h
//  LemurCam
//
//  Shared, language-neutral contract between three processes:
//    * the LemurCam app          — PRODUCER, writes decoded camera PCM
//    * the AudioServerPlugIn      — CONSUMER, runs inside sandboxed `coreaudiod`,
//                                   reads PCM in its real-time IO callback
//    * the privileged helper      — neither; only installs the .driver bundle
//
//  Everything both the C driver and the Swift app must agree on lives here so
//  there is a single source of truth for the ring-buffer layout, the shared
//  memory name, the published audio format, and the demand-signalling
//  notification names.
//
//  IMPORTANT (POSIX shm name length): on macOS, shm_open names are limited to
//  PSHMNAMLEN (31) characters including the leading '/'. Keep
//  LEMUR_AUDIO_SHM_NAME short. App-group-prefixed names would exceed that and
//  fail with ENAMETOOLONG, so we use a short global name. Whether `coreaudiod`'s
//  sandbox permits opening this region is the load-bearing unknown the Phase A
//  spike must confirm; if it is blocked, the fallback is an XPC bridge (see the
//  plan). Do not assume it works until verified on-device.
//

#pragma once

#include <stdint.h>
#include <stdatomic.h>
#include <string.h>

#ifdef __cplusplus
extern "C" {
#endif

// MARK: - Identity

/// Bundle identifier of the AudioServerPlugIn .driver.
#define LEMUR_AUDIO_PLUGIN_BUNDLE_ID "cam.lemur.app.audio"

/// Stable Core Audio device UID for the virtual microphone. Must remain
/// constant across reboots and driver reloads so consuming apps remember the
/// selection. Also used to pair with the camera via linkedCoreAudioDeviceUID.
#define LEMUR_AUDIO_DEVICE_UID "cam.lemur.app.microphone"

/// Human-readable device name shown in microphone pickers.
#define LEMUR_AUDIO_DEVICE_NAME "LemurCam Microphone"

/// Manufacturer string for the device/box.
#define LEMUR_AUDIO_MANUFACTURER "LemurCam"

// MARK: - Published audio format
//
// The device publishes a single canonical Core Audio format. The app resamples
// whatever the camera delivers (8 kHz G.711, 16/48 kHz AAC, ...) to this format
// before writing into the ring, so the driver never has to convert.

#define LEMUR_AUDIO_SAMPLE_RATE   48000.0   // Hz
#define LEMUR_AUDIO_CHANNELS      2u        // interleaved stereo (mono is upmixed)
#define LEMUR_AUDIO_BITS_PER_CH   32u       // Float32

// Bytes per interleaved frame. Defined as a plain literal (not a computed
// expression) so the Swift Clang importer can actually see it — computed macros
// are silently dropped by the importer. The _Static_assert keeps it honest if
// the channel/bit-depth constants ever change. Imports into Swift as UInt32
// (use Int(...) when a count is needed).
#define LEMUR_AUDIO_BYTES_PER_FRAME 8u
_Static_assert(LEMUR_AUDIO_BYTES_PER_FRAME ==
                   LEMUR_AUDIO_CHANNELS * (LEMUR_AUDIO_BITS_PER_CH / 8u),
               "LEMUR_AUDIO_BYTES_PER_FRAME out of sync with channel/bit-depth constants");

// MARK: - Shared memory ring buffer

/// Shared memory region name. Keep <= 31 chars including the leading '/'.
/// ("/cam.lemur.audioring" is 20 chars.)
#define LEMUR_AUDIO_SHM_NAME "/cam.lemur.audioring"

/// Sanity marker so a process can detect an uninitialised / wrong-version region.
#define LEMUR_AUDIO_RING_MAGIC   0x4C454D52u   // 'LEMR'

/// Ring capacity in frames. MUST be a power of two (the index math masks with
/// capacity-1). 16384 frames ≈ 341 ms at 48 kHz — generous headroom for network
/// jitter while keeping latency bounded.
#define LEMUR_AUDIO_RING_CAPACITY_FRAMES 16384u
_Static_assert((LEMUR_AUDIO_RING_CAPACITY_FRAMES &
                (LEMUR_AUDIO_RING_CAPACITY_FRAMES - 1u)) == 0u,
               "LEMUR_AUDIO_RING_CAPACITY_FRAMES must be a power of two for index masking");

/// Slot mask. Every helper masks with this compile-time constant and sizes its
/// copies from LEMUR_AUDIO_RING_CAPACITY_FRAMES, never from the shared
/// `capacityFrames` field: the region is writable by the other process, and a
/// header that changes after lemur_ring_ready() passed (capacityFrames == 0
/// would make a field-derived mask 0xFFFFFFFF) must not be able to steer an
/// access outside `samples`.
#define LEMUR_AUDIO_RING_INDEX_MASK (LEMUR_AUDIO_RING_CAPACITY_FRAMES - 1u)

/// Lock-free single-producer / single-consumer ring of interleaved Float32 PCM.
///
/// `writeIndex` / `readIndex` are free-running frame counters (they wrap at
/// 2^32; unsigned subtraction stays correct across the wrap). The number of
/// readable frames is `writeIndex - readIndex`, which the helpers keep within
/// [0, capacity]. A distance outside that range (inverted or corrupted indices)
/// is treated as an empty ring and reset by whichever side touches it next, so
/// stale audio is never replayed. Aligned 32-bit loads/stores are atomic on Apple
/// silicon and Intel; ordering is established with explicit acquire/release
/// fences inside the inline helpers below (the classic TPCircularBuffer
/// approach). No member is declared _Atomic so the struct imports cleanly into
/// Swift; Swift must only ever touch the ring through the inline helpers, never
/// the fields directly.
typedef struct {
    uint32_t magic;             // == LEMUR_AUDIO_RING_MAGIC once initialised
    uint32_t capacityFrames;    // == LEMUR_AUDIO_RING_CAPACITY_FRAMES (layout
                                // check only; never used for indexing)
    uint32_t channels;          // == LEMUR_AUDIO_CHANNELS
    uint32_t reserved;          // padding / future use

    volatile uint32_t writeIndex;   // producer-owned (app)
    volatile uint32_t readIndex;    // consumer-owned (driver)
    volatile uint64_t lastWriteHostTime; // mach_absolute_time() of last write;
                                         // published before writeIndex so it is
                                         // ordered with the batch (see write())
    volatile int32_t  producing;    // 1 while the app is actively producing
                                    // (app-owned; the driver never reads it)

    float samples[LEMUR_AUDIO_RING_CAPACITY_FRAMES * LEMUR_AUDIO_CHANNELS];
} LemurAudioRing;

/// One-time initialisation, performed by the PRODUCER after mapping the region.
static inline void lemur_ring_init(LemurAudioRing *ring) {
    ring->capacityFrames = LEMUR_AUDIO_RING_CAPACITY_FRAMES;
    ring->channels = LEMUR_AUDIO_CHANNELS;
    ring->reserved = 0;
    ring->writeIndex = 0;
    ring->readIndex = 0;
    ring->lastWriteHostTime = 0;
    ring->producing = 0;
    memset(ring->samples, 0, sizeof(ring->samples));
    atomic_thread_fence(memory_order_release);
    ring->magic = LEMUR_AUDIO_RING_MAGIC;
}

/// CONSUMER: returns non-zero once the producer has run lemur_ring_init and the
/// region's layout matches this build. Pairs (acquire) with the release fence in
/// lemur_ring_init so a true result guarantees the initialised fields are
/// visible. A freshly created shm object is zero-filled, so this correctly
/// reports "not ready" (magic == 0) until the producer initialises it. This is a
/// compatibility check, not a safety check: the other process can rewrite the
/// header right after it passes, which is why no helper trusts those fields.
static inline int lemur_ring_ready(const LemurAudioRing *ring) {
    uint32_t m = ring->magic;
    atomic_thread_fence(memory_order_acquire);
    return m == LEMUR_AUDIO_RING_MAGIC
        && ring->capacityFrames == LEMUR_AUDIO_RING_CAPACITY_FRAMES
        && ring->channels == LEMUR_AUDIO_CHANNELS;
}

/// Readable frames for a (writeIndex, readIndex) pair, or 0 when the distance is
/// out of range. The helpers never produce a distance above the capacity; one
/// means the indices were inverted or corrupted, and nothing in the ring can be
/// trusted to be current, so it reads as empty.
static inline uint32_t lemur_ring_distance(uint32_t w, uint32_t r) {
    uint32_t d = w - r;
    return d <= LEMUR_AUDIO_RING_CAPACITY_FRAMES ? d : 0u;
}

/// CONSUMER-side: discard all currently buffered frames so the next read starts
/// from the most recent data. Call ONLY from the consumer (or before the
/// consumer's real-time thread is running) — never from the producer, since
/// readIndex is consumer-owned. Used to drop stale backlog when (re)starting a
/// session so a new consumer does not replay queued audio as latency.
static inline void lemur_ring_reset_read(LemurAudioRing *ring) {
    uint32_t w = ring->writeIndex;
    atomic_thread_fence(memory_order_acquire);
    ring->readIndex = w;
    atomic_thread_fence(memory_order_release);
}

/// Frames currently available to read (0 if the indices are out of range).
static inline uint32_t lemur_ring_filled(const LemurAudioRing *ring) {
    uint32_t w = ring->writeIndex;
    atomic_thread_fence(memory_order_acquire);
    uint32_t r = ring->readIndex;
    return lemur_ring_distance(w, r);
}

/// Free frames available to write. Always within [0, capacity].
static inline uint32_t lemur_ring_free(const LemurAudioRing *ring) {
    return LEMUR_AUDIO_RING_CAPACITY_FRAMES - lemur_ring_filled(ring);
}

/// PRODUCER: append up to `frames` interleaved Float32 frames from `src`.
/// Returns the number of frames actually written. When the ring is full the
/// tail of the batch is dropped rather than blocking or overwriting slots the
/// consumer may be reading (readIndex is consumer-owned, so the producer cannot
/// drop the oldest audio itself). Out-of-range indices are resynced to the
/// reader first, so a corrupted ring heals on the next write.
static inline uint32_t lemur_ring_write(LemurAudioRing *ring,
                                        const float *src,
                                        uint32_t frames,
                                        uint64_t hostTime) {
    uint32_t w = ring->writeIndex;
    uint32_t r = ring->readIndex;
    // Pairs with the consumer's release before it publishes readIndex: slots it
    // has finished reading are only overwritten after that store is observed.
    atomic_thread_fence(memory_order_acquire);
    uint32_t d = w - r;
    if (d > LEMUR_AUDIO_RING_CAPACITY_FRAMES) {
        w = r;
        d = 0;
    }
    uint32_t freeFrames = LEMUR_AUDIO_RING_CAPACITY_FRAMES - d;
    uint32_t n = frames < freeFrames ? frames : freeFrames;
    for (uint32_t i = 0; i < n; i++) {
        uint32_t slot = (w + i) & LEMUR_AUDIO_RING_INDEX_MASK;
        for (uint32_t c = 0; c < LEMUR_AUDIO_CHANNELS; c++) {
            ring->samples[slot * LEMUR_AUDIO_CHANNELS + c] =
                src[i * LEMUR_AUDIO_CHANNELS + c];
        }
    }
    // Publish the timestamp before the release fence so a consumer that syncs on
    // the new writeIndex observes the host time matching this batch of frames.
    ring->lastWriteHostTime = hostTime;
    atomic_thread_fence(memory_order_release);
    ring->writeIndex = w + n;
    return n;
}

/// PRODUCER: discard every unread frame by moving writeIndex back to the
/// consumer's position, so a consumer that does not reset its read position on
/// start (drivers before this change) never starts on stale backlog. Call only
/// while no consumer should be reading (production stopped or just restarted).
/// If a consumer read does race it, the consumer can advance past the new
/// writeIndex; both sides then see an out-of-range distance and reset instead of
/// replaying old audio. No store when the ring is already drained.
static inline void lemur_ring_discard(LemurAudioRing *ring) {
    uint32_t r = ring->readIndex;
    atomic_thread_fence(memory_order_acquire);
    uint32_t w = ring->writeIndex;
    if (w != r) {
        ring->writeIndex = r;
    }
}

/// PRODUCER: set or clear the app-owned `producing` flag.
static inline void lemur_ring_set_producing(LemurAudioRing *ring, int producing) {
    ring->producing = producing ? 1 : 0;
}

/// Whether the app-owned `producing` flag is set.
static inline int lemur_ring_is_producing(const LemurAudioRing *ring) {
    return ring->producing != 0;
}

/// CONSUMER (real-time safe): read exactly `frames` frames into `dst`, zero-
/// filling any shortfall (underrun => silence). Returns frames actually copied
/// from the ring (the remainder, if any, was zero-filled). Out-of-range indices
/// move the read position to the write head, so the read returns silence
/// instead of replaying whatever the slots hold.
static inline uint32_t lemur_ring_read(LemurAudioRing *ring,
                                       float *dst,
                                       uint32_t frames) {
    uint32_t w = ring->writeIndex;
    atomic_thread_fence(memory_order_acquire);
    uint32_t r = ring->readIndex;
    if (w - r > LEMUR_AUDIO_RING_CAPACITY_FRAMES) {
        r = w;
    }
    uint32_t avail = w - r;
    uint32_t n = frames < avail ? frames : avail;
    for (uint32_t i = 0; i < n; i++) {
        uint32_t slot = (r + i) & LEMUR_AUDIO_RING_INDEX_MASK;
        for (uint32_t c = 0; c < LEMUR_AUDIO_CHANNELS; c++) {
            dst[i * LEMUR_AUDIO_CHANNELS + c] =
                ring->samples[slot * LEMUR_AUDIO_CHANNELS + c];
        }
    }
    if (n < frames) {
        memset(dst + (size_t)n * LEMUR_AUDIO_CHANNELS, 0,
               (size_t)(frames - n) * LEMUR_AUDIO_CHANNELS * sizeof(float));
    }
    atomic_thread_fence(memory_order_release);
    ring->readIndex = r + n;
    return n;
}

// MARK: - Demand signalling (Darwin notifications)
//
// The driver posts these from StartIO/StopIO via
// CFNotificationCenterGetDarwinNotifyCenter(). The app observes them to drive
// audio demand, mirroring the camera's consumerStarted/Stopped pattern. Swift
// imports these object-like string macros as `String` constants.

#define LEMUR_AUDIO_NOTIFY_CONSUMER_STARTED "cam.lemur.audioConsumerStarted"
#define LEMUR_AUDIO_NOTIFY_CONSUMER_STOPPED "cam.lemur.audioConsumerStopped"

#ifdef __cplusplus
}
#endif

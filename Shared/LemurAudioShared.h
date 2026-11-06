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
/// capacity-1). 16384 frames ≈ 341 ms at 48 kHz: headroom for network jitter.
/// Latency is not set by the capacity; the consumer trims the backlog to
/// LEMUR_AUDIO_RING_TARGET_FRAMES plus what recent stalls need (see
/// lemur_ring_read_paced).
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

// MARK: Consumer latency policy
//
// Producer and consumer run at the same nominal rate, so any backlog the ring
// picks up (a burst after a network stall, a jitter underrun that delays every
// later frame, camera clock drift) would otherwise stay as permanent latency, up
// to the full capacity. The consumer therefore tracks the smallest backlog it
// leaves behind over each window. If even that floor stayed above the high-water
// mark for a whole window, the excess is old audio, so it skips ahead to the
// target. A floor (not an average) is used so a producer that writes in large
// packets (e.g. 64 ms AAC frames) is not mistaken for backlog.
//
// The backlog left by a network stall is not all excess: it is exactly the
// cushion that rides out the next stall of the same length. Trimming it back to
// 50 ms turned every later stall into an underrun plus a skip. So the consumer
// also measures the longest gap between producer writes in each window, and keeps
// a reserve on top of the target large enough to cover the longest gap of the
// last 30 to 60 s. Stalls that keep coming within that time are then absorbed as
// they are, with no trimming, while the cushion a one-off stall left behind is
// still trimmed, in one skip, once that stall has aged out.

/// Backlog the consumer trims down to: 2400 frames = 50 ms at 48 kHz, enough to
/// ride out LAN/Wi-Fi packet jitter without audible underruns.
#define LEMUR_AUDIO_RING_TARGET_FRAMES 2400u
/// Trim only when the backlog floor stayed above 4800 frames (100 ms) for a whole
/// window. The gap above the target is hysteresis: slow clock drift then costs
/// one skip every few minutes instead of a click every window. The reserve
/// raises the trim point by the same amount as the target.
#define LEMUR_AUDIO_RING_HIGH_WATER_FRAMES 4800u
/// Window over which the backlog floor is measured: 48000 frames = 1 s of reads.
#define LEMUR_AUDIO_RING_PACER_WINDOW_FRAMES 48000u
/// Most reserve kept on top of the target: 7200 frames (150 ms), so the backlog
/// the pacer trims down to never exceeds 200 ms however long the stalls are.
#define LEMUR_AUDIO_RING_RESERVE_MAX_FRAMES 7200u
/// Gaps are remembered per period of this many windows (30 s); the reserve
/// covers the longest gap of the current and the previous period.
#define LEMUR_AUDIO_RING_RESERVE_PERIOD_WINDOWS 30u
_Static_assert(LEMUR_AUDIO_RING_TARGET_FRAMES < LEMUR_AUDIO_RING_HIGH_WATER_FRAMES &&
                   LEMUR_AUDIO_RING_HIGH_WATER_FRAMES < LEMUR_AUDIO_RING_CAPACITY_FRAMES,
               "ring latency policy must satisfy target < high water < capacity");
_Static_assert(LEMUR_AUDIO_RING_HIGH_WATER_FRAMES + LEMUR_AUDIO_RING_RESERVE_MAX_FRAMES <
                   LEMUR_AUDIO_RING_CAPACITY_FRAMES,
               "the learned reserve must leave the trim point below the ring capacity");

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
/// drop the oldest audio itself). A full ring only happens when the consumer
/// stalls or a burst exceeds the capacity; lemur_ring_read_paced then drops the
/// oldest audio on its next read, so fullness does not persist. Out-of-range
/// indices are resynced to the reader first, so a corrupted ring heals on the
/// next write.
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

/// Consumer-private pacing state for lemur_ring_read_paced. Lives in the
/// consumer's own memory, never in the shared region. Initialise it, and reset
/// it at the start of every IO session, with lemur_ring_pacer_reset.
typedef struct {
    uint32_t windowFrames;    // frames requested so far in the current window
    uint32_t minBacklog;      // smallest backlog left after a read in the window
    uint32_t lastWrite;       // writeIndex seen by the previous read
    uint32_t sinceWrite;      // frames requested since writeIndex last moved
    uint32_t windowGap;       // longest gap between writes that ended in the window
    uint32_t reserve;         // reserve the current period's gaps need
    uint32_t previousReserve; // reserve the previous period's gaps needed
    uint32_t periodWindows;   // windows completed in the current period
} LemurAudioRingPacer;

/// Start a new measuring window; the reserve and write tracking carry over.
static inline void lemur_ring_pacer_new_window(LemurAudioRingPacer *pacer) {
    pacer->windowFrames = 0;
    pacer->minBacklog = UINT32_MAX;
    pacer->windowGap = 0;
}

/// Forget everything, including the reserve (a new IO session).
static inline void lemur_ring_pacer_reset(LemurAudioRingPacer *pacer) {
    lemur_ring_pacer_new_window(pacer);
    pacer->lastWrite = 0;
    pacer->sinceWrite = 0;
    pacer->reserve = 0;
    pacer->previousReserve = 0;
    pacer->periodWindows = 0;
}

/// Backlog the pacer trims down to: the target plus the reserve, clamped so the
/// trim point always stays below the capacity.
static inline uint32_t lemur_ring_pacer_keep(const LemurAudioRingPacer *pacer) {
    uint32_t reserve = pacer->reserve > pacer->previousReserve
        ? pacer->reserve : pacer->previousReserve;
    if (reserve > LEMUR_AUDIO_RING_RESERVE_MAX_FRAMES) {
        reserve = LEMUR_AUDIO_RING_RESERVE_MAX_FRAMES;
    }
    return LEMUR_AUDIO_RING_TARGET_FRAMES + reserve;
}

/// Note whether the producer wrote since the previous read. The frames requested
/// in between are how long the ring had to cover on its own, i.e. the backlog a
/// gap of that length needs. A gap as long as the ring is an outage (the producer
/// stopped, or the session just started), not jitter: no backlog could have
/// covered it, so it is not learned.
static inline void lemur_ring_pacer_track_writes(LemurAudioRingPacer *pacer,
                                                 uint32_t w,
                                                 uint32_t frames) {
    if (w != pacer->lastWrite) {
        if (pacer->sinceWrite < LEMUR_AUDIO_RING_CAPACITY_FRAMES &&
            pacer->sinceWrite > pacer->windowGap) {
            pacer->windowGap = pacer->sinceWrite;
        }
        pacer->lastWrite = w;
        pacer->sinceWrite = 0;
    }
    uint32_t room = UINT32_MAX - pacer->sinceWrite;
    pacer->sinceWrite = frames < room ? pacer->sinceWrite + frames : UINT32_MAX;
}

/// End of a window: fold its longest gap into the current period's reserve, and
/// roll the periods over once the current one is complete.
static inline void lemur_ring_pacer_learn(LemurAudioRingPacer *pacer) {
    if (pacer->windowGap > LEMUR_AUDIO_RING_TARGET_FRAMES) {
        uint32_t needed = pacer->windowGap - LEMUR_AUDIO_RING_TARGET_FRAMES;
        if (needed > pacer->reserve) {
            pacer->reserve = needed;
        }
    }
    pacer->periodWindows++;
    if (pacer->periodWindows >= LEMUR_AUDIO_RING_RESERVE_PERIOD_WINDOWS) {
        pacer->previousReserve = pacer->reserve;
        pacer->reserve = 0;
        pacer->periodWindows = 0;
    }
}

/// Applies the latency policy to a read of `frames` frames at in-range indices
/// (w, r) and returns the read position to use. Pure index math, real-time safe.
static inline uint32_t lemur_ring_pace(LemurAudioRingPacer *pacer,
                                       uint32_t w,
                                       uint32_t r,
                                       uint32_t frames) {
    uint32_t d = w - r;
    lemur_ring_pacer_track_writes(pacer, w, frames);
    if (d >= LEMUR_AUDIO_RING_CAPACITY_FRAMES) {
        // Full: the producer is dropping the newest audio. Drop the oldest
        // instead, leaving the kept backlog behind after this read (a read
        // larger than the excess skips nothing).
        lemur_ring_pacer_new_window(pacer);
        uint32_t keep = lemur_ring_pacer_keep(pacer);
        return frames < d - keep ? w - (keep + frames) : r;
    }
    uint32_t backlog = d > frames ? d - frames : 0u;
    if (backlog < pacer->minBacklog) {
        pacer->minBacklog = backlog;
    }
    uint32_t room = LEMUR_AUDIO_RING_PACER_WINDOW_FRAMES - pacer->windowFrames;
    pacer->windowFrames = frames < room ? pacer->windowFrames + frames
                                        : LEMUR_AUDIO_RING_PACER_WINDOW_FRAMES;
    if (pacer->windowFrames < LEMUR_AUDIO_RING_PACER_WINDOW_FRAMES) {
        return r;
    }
    uint32_t backlogFloor = pacer->minBacklog;
    lemur_ring_pacer_learn(pacer);
    lemur_ring_pacer_new_window(pacer);
    uint32_t keep = lemur_ring_pacer_keep(pacer);
    // `backlogFloor` includes this read's backlog (d - frames), so the skip always
    // leaves at least `frames` + `keep` frames readable.
    return backlogFloor > keep + (LEMUR_AUDIO_RING_HIGH_WATER_FRAMES - LEMUR_AUDIO_RING_TARGET_FRAMES)
        ? r + (backlogFloor - keep)
        : r;
}

/// CONSUMER (real-time safe): read exactly `frames` frames into `dst`, zero-
/// filling any shortfall (underrun => silence). Returns frames actually copied
/// from the ring (the remainder, if any, was zero-filled). With a non-NULL
/// `pacer` the backlog is held near LEMUR_AUDIO_RING_TARGET_FRAMES plus the
/// reserve recent stalls need (see the latency policy above); with NULL every
/// buffered frame is played in order.
/// Out-of-range indices move the read position to the write head, so the read
/// returns silence instead of replaying whatever the slots hold.
static inline uint32_t lemur_ring_read_paced(LemurAudioRing *ring,
                                             LemurAudioRingPacer *pacer,
                                             float *dst,
                                             uint32_t frames) {
    uint32_t w = ring->writeIndex;
    atomic_thread_fence(memory_order_acquire);
    uint32_t r = ring->readIndex;
    if (w - r > LEMUR_AUDIO_RING_CAPACITY_FRAMES) {
        r = w;
        if (pacer != NULL) {
            lemur_ring_pacer_reset(pacer);
        }
    } else if (pacer != NULL) {
        r = lemur_ring_pace(pacer, w, r, frames);
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

/// CONSUMER (real-time safe): lemur_ring_read_paced without latency control.
static inline uint32_t lemur_ring_read(LemurAudioRing *ring,
                                       float *dst,
                                       uint32_t frames) {
    return lemur_ring_read_paced(ring, NULL, dst, frames);
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

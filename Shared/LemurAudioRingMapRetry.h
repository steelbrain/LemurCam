//
//  LemurAudioRingMapRetry.h
//  LemurCam
//
//  When the driver tries to map the app's shared-memory ring (LemurAudioShared.h)
//  and when its background retry keeps going. Used by the driver, which calls
//  these under gStateMutex, and by the app's unit tests through the bridging
//  header.
//
//  The region exists only once the app has run since boot, and a client can start
//  recording from the microphone long before that. The driver only mapped the ring
//  on the first client's StartIO, and its retry gave up after about 60 s, so an
//  app opened later left the microphone silent until every client stopped. It now
//  maps whenever a client starts IO with no ring mapped, whichever client that
//  is, and the retry keeps trying, once a second, for as long as any client runs
//  IO.
//

#pragma once

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Whether the driver should try to map the ring now: while any client runs IO
/// (`ioCount` > 0) and no ring is mapped. StartIO asks after counting its client,
/// and the retry asks before each attempt. Neither which client started nor how
/// long the region has been missing matters.
static inline bool lemur_audio_ring_map_wanted(uint32_t ioCount, bool ringMapped) {
    return ioCount > 0 && !ringMapped;
}

/// StartIO, after a map attempt failed: whether to start the retry thread. Returns
/// true, and marks the retry running in `*retryRunning`, only when none runs, so
/// at most one retry thread exists.
static inline bool lemur_audio_ring_map_retry_claim(bool *_Nonnull retryRunning) {
    if (*retryRunning) { return false; }
    *retryRunning = true;
    return true;
}

/// The retry thread, after each attempt: whether to sleep and try again, which it
/// does as long as the ring is still wanted. When it stops, it clears
/// `*retryRunning` in the same lock hold as the decision, so a StartIO that comes
/// right after it starts a new retry instead of counting on this one.
static inline bool lemur_audio_ring_map_retry_continues(uint32_t ioCount, bool ringMapped,
                                                        bool *_Nonnull retryRunning) {
    if (lemur_audio_ring_map_wanted(ioCount, ringMapped)) { return true; }
    *retryRunning = false;
    return false;
}

#ifdef __cplusplus
}
#endif

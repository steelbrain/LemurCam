//
//  LemurAudioConsumerSignal.h
//  LemurCam
//
//  Which demand notification (LemurAudioShared.h) the driver posts when a client
//  starts or stops IO on the virtual microphone. Used by the driver, which calls
//  these under gStateMutex and posts what they return before unlocking, and by the
//  app's unit tests through the bridging header.
//
//  The app takes each notification's direction as the device's state
//  (VirtualMicDemand), so the notifications must leave the driver in the order the
//  count changed. Posted after unlocking, one client's last StopIO and another's
//  first StartIO could post in the opposite order: "started", then "stopped" while
//  the second client records.
//

#pragma once

#include <stddef.h>
#include <stdint.h>

#include "LemurAudioShared.h"

#ifdef __cplusplus
extern "C" {
#endif

/// A client starts IO: counts it in `*ioCount`, and returns the notification to
/// post (consumerStarted for the first client), or NULL.
static inline const char *_Nullable lemur_audio_io_started(uint32_t *_Nonnull ioCount) {
    const char *notification = (*ioCount == 0) ? LEMUR_AUDIO_NOTIFY_CONSUMER_STARTED : NULL;
    ++*ioCount;
    return notification;
}

/// A client stops IO: uncounts it from `*ioCount`, and returns the notification to
/// post (consumerStopped once no client runs IO, also after a StopIO with none
/// counted, which only repeats the truth), or NULL.
static inline const char *_Nullable lemur_audio_io_stopped(uint32_t *_Nonnull ioCount) {
    if (*ioCount > 0) { --*ioCount; }
    return (*ioCount == 0) ? LEMUR_AUDIO_NOTIFY_CONSUMER_STOPPED : NULL;
}

#ifdef __cplusplus
}
#endif

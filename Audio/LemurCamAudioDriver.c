//
//  LemurCamAudioDriver.c
//  LemurCam virtual microphone — AudioServerPlugIn
//
//  A minimal Core Audio AudioServerPlugIn that publishes a single virtual INPUT
//  device, "LemurCam Microphone". It runs inside the sandboxed `coreaudiod`
//  process and is the ONLY supported way to expose a virtual microphone on
//  macOS 14+ (CoreMediaIO is video-only; AudioDriverKit is not granted for
//  virtual devices). See AGENTS.md / the plan.
//
//  Audio source: the LemurCam app decodes the camera's audio to 48 kHz Float32
//  stereo PCM and writes it into a shared-memory ring buffer (LemurAudioShared.h).
//  This driver maps that ring and hands the frames back from its real-time input
//  IO callback, emitting silence on underrun or when the app is not producing.
//
//  Structure follows Apple's NullAudio sample, reduced to one input device with
//  no box and no controls. The object graph is static:
//      PlugIn (kObjectID_PlugIn) -> Device (kObjectID_Device) -> Stream (input)
//
//  Real-time rule: DoIOOperation / GetZeroTimeStamp run on a high-priority audio
//  thread and MUST NOT lock, allocate, or make syscalls. Only the lock-free ring
//  read happens there. Mapping the shm region and posting notifications happen on
//  the non-real-time Start/StopIO path under gStateMutex.
//

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <string.h>
#include <os/log.h>

#include "LemurAudioShared.h"

// MARK: - Object IDs (static graph)

enum {
    kObjectID_PlugIn       = kAudioObjectPlugInObject, // 1
    kObjectID_Device       = 2,
    kObjectID_Stream_Input = 3
};

#define kDevice_ModelUID            "cam.lemur.app.microphone.model"
// Number of frames between zero timestamps. Defines the device timeline cadence;
// independent of the shm ring capacity. Power-of-two, comfortably larger than a
// typical IO buffer.
#define kDevice_ZeroTimeStampPeriod 16384u

// Frames the HAL stays behind the write head when reading input, giving the
// producer a small head start so the consumer's first reads don't land on
// not-yet-written frames (which the ring would zero-fill as a brief gap).
// ~10.7 ms at 48 kHz — imperceptible for a network-camera microphone.
#define kDevice_SafetyOffset 512u

// Ring-map retry (see StartRingMapRetry): if the shm region does not exist when
// the first consumer starts IO (e.g. the app has not launched yet since boot),
// retry mapping it off the real-time path so audio begins as soon as the app
// creates the ring, without forcing the consumer to restart the device.
#define kRingMapRetryMaxAttempts 60        // ~60 s total
#define kRingMapRetryIntervalUsec 1000000  // 1 s between attempts

static os_log_t gLog;
#define LEMUR_LOG_INIT() do { if (gLog == NULL) { gLog = os_log_create("cam.lemur.app.audio", "driver"); } } while (0)

// MARK: - Globals

static AudioServerPlugInHostRef gPlugInHost = NULL;

// Guards non-real-time state (IO refcount, shm mapping, timeline anchor).
static pthread_mutex_t gStateMutex = PTHREAD_MUTEX_INITIALIZER;

static UInt32  gIOCount = 0;                     // number of clients running IO
static Float64 gSampleRate = LEMUR_AUDIO_SAMPLE_RATE;
static Boolean gStreamIsActive = true;

// Device timeline (NullAudio-style). Anchored at StartIO.
static Float64 gHostTicksPerFrame = 0.0;
static UInt64  gAnchorHostTime = 0;
static UInt64  gNumberTimeStamps = 0;

// Shared-memory ring (mapped lazily in StartIO; survives until the plug-in
// unloads). Published with release/acquire ordering: StartIO maps and stores it
// (release) under gStateMutex; the real-time DoIOOperation loads it (acquire)
// once into a local, so it never observes a half-published pointer and stays
// lock-free.
static int                     gShmFD = -1;
static LemurAudioRing *_Atomic gRing = NULL;

// Set while a background ring-map retry thread is running, so StartIO never
// spawns a second one. Cleared by the thread when it exits.
static atomic_int gMapRetryRunning = 0;

// MARK: - Helpers

static void FillFormat(AudioStreamBasicDescription *format) {
    memset(format, 0, sizeof(*format));
    format->mSampleRate       = gSampleRate;
    format->mFormatID         = kAudioFormatLinearPCM;
    format->mFormatFlags      = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    format->mBytesPerPacket   = LEMUR_AUDIO_BYTES_PER_FRAME;
    format->mFramesPerPacket  = 1;
    format->mBytesPerFrame    = LEMUR_AUDIO_BYTES_PER_FRAME;
    format->mChannelsPerFrame = LEMUR_AUDIO_CHANNELS;
    format->mBitsPerChannel   = LEMUR_AUDIO_BITS_PER_CH;
}

// Map the app-created shm ring. Non-real-time; call from Start/StopIO only.
// Returns true if the ring is mapped (it may still be "not ready" until the app
// initialises it). Safe to call repeatedly.
static Boolean EnsureRingMapped(void) {
    if (atomic_load_explicit(&gRing, memory_order_acquire) != NULL) {
        return true;
    }
    int fd = shm_open(LEMUR_AUDIO_SHM_NAME, O_RDWR, 0);
    if (fd < 0) {
        os_log_error(gLog, "shm_open(%{public}s) failed: %d — emitting silence",
                     LEMUR_AUDIO_SHM_NAME, errno);
        return false;
    }
    void *p = mmap(NULL, sizeof(LemurAudioRing), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (p == MAP_FAILED) {
        os_log_error(gLog, "mmap of ring failed: %d", errno);
        close(fd);
        return false;
    }
    LemurAudioRing *ring = (LemurAudioRing *)p;
    // Drop any backlog before publishing the pointer, so the consumer's first
    // read starts on current audio rather than replaying queued frames as
    // latency. Doing this *before* the atomic store is what makes it safe from
    // the background retry path too: the real-time thread cannot observe gRing
    // (and therefore cannot touch the consumer-owned readIndex) until after this
    // reset completes, so there is never a second writer racing readIndex.
    if (lemur_ring_ready(ring)) { lemur_ring_reset_read(ring); }
    gShmFD = fd;
    atomic_store_explicit(&gRing, ring, memory_order_release);
    os_log(gLog, "mapped audio ring buffer");
    return true;
}

// Background worker: retry EnsureRingMapped until it succeeds, IO stops, or the
// attempt cap is reached. Non-real-time (it sleeps and makes syscalls), so it
// runs on its own detached thread, never on the IO thread. Each attempt holds
// gStateMutex only for the (fast, sleep-free) map call; the sleep is outside the
// lock so it never stalls Start/StopIO.
static void *RingMapRetryThread(void *arg) {
    (void)arg;
    for (int attempt = 0; attempt < kRingMapRetryMaxAttempts; attempt++) {
        pthread_mutex_lock(&gStateMutex);
        Boolean ioRunning = (gIOCount > 0);
        Boolean mapped = ioRunning ? EnsureRingMapped() : true;
        pthread_mutex_unlock(&gStateMutex);
        if (mapped || !ioRunning) { break; }
        usleep(kRingMapRetryIntervalUsec);
    }
    atomic_store_explicit(&gMapRetryRunning, 0, memory_order_release);
    return NULL;
}

// Spawn the retry worker if one is not already running. Call with gStateMutex
// held (from StartIO); pthread_create does not need the lock and the worker
// blocks on the mutex until StartIO releases it.
static void StartRingMapRetry(void) {
    int expected = 0;
    if (!atomic_compare_exchange_strong(&gMapRetryRunning, &expected, 1)) {
        return; // a retry thread is already running
    }
    pthread_t tid;
    if (pthread_create(&tid, NULL, RingMapRetryThread, NULL) == 0) {
        pthread_detach(tid);
    } else {
        os_log_error(gLog, "failed to start ring-map retry thread");
        atomic_store_explicit(&gMapRetryRunning, 0, memory_order_release);
    }
}

static void PostDarwinNotification(const char *name) {
    CFStringRef cfName = CFStringCreateWithCString(kCFAllocatorDefault, name, kCFStringEncodingUTF8);
    if (cfName != NULL) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             cfName, NULL, NULL, true);
        CFRelease(cfName);
    }
}

// MARK: - COM / IUnknown plumbing

static HRESULT QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface);
static ULONG   AddRef(void *inDriver);
static ULONG   Release(void *inDriver);

static OSStatus Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
static OSStatus CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription,
                             const AudioServerPlugInClientInfo *inClientInfo, AudioObjectID *outDeviceObjectID);
static OSStatus DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID);
static OSStatus AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                const AudioServerPlugInClientInfo *inClientInfo);
static OSStatus RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                   const AudioServerPlugInClientInfo *inClientInfo);
static OSStatus PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                                 UInt64 inChangeAction, void *inChangeInfo);
static OSStatus AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                               UInt64 inChangeAction, void *inChangeInfo);

static Boolean  HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID,
                            const AudioObjectPropertyAddress *inAddress);
static OSStatus IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID,
                                   const AudioObjectPropertyAddress *inAddress, Boolean *outIsSettable);
static OSStatus GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID,
                                    const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize,
                                    const void *inQualifierData, UInt32 *outDataSize);
static OSStatus GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID,
                                const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize,
                                const void *inQualifierData, UInt32 inDataSize, UInt32 *outDataSize, void *outData);
static OSStatus SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID,
                                const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize,
                                const void *inQualifierData, UInt32 inDataSize, const void *inData);

static OSStatus StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                 Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed);
static OSStatus WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                  UInt32 inOperationID, Boolean *outWillDo, Boolean *outWillDoInPlace);
static OSStatus BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                 UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                 const AudioServerPlugInIOCycleInfo *inIOCycleInfo);
static OSStatus DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                              AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID,
                              UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo,
                              void *ioMainBuffer, void *ioSecondaryBuffer);
static OSStatus EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                               UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                               const AudioServerPlugInIOCycleInfo *inIOCycleInfo);

static AudioServerPlugInDriverInterface gInterface = {
    NULL,
    QueryInterface,
    AddRef,
    Release,
    Initialize,
    CreateDevice,
    DestroyDevice,
    AddDeviceClient,
    RemoveDeviceClient,
    PerformDeviceConfigurationChange,
    AbortDeviceConfigurationChange,
    HasProperty,
    IsPropertySettable,
    GetPropertyDataSize,
    GetPropertyData,
    SetPropertyData,
    StartIO,
    StopIO,
    GetZeroTimeStamp,
    WillDoIOOperation,
    BeginIOOperation,
    DoIOOperation,
    EndIOOperation
};

static AudioServerPlugInDriverInterface *gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef gDriverRef = &gInterfacePtr;
static UInt32 gRefCount = 1;

// Exported factory (referenced by Info.plist CFPlugInFactories).
void *LemurCamAudioDriverFactory(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID);
void *LemurCamAudioDriverFactory(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID) {
    (void)inAllocator;
    LEMUR_LOG_INIT();
    // kAudioServerPlugInTypeUUID is a constant CFUUIDRef (CFUUIDGetConstantUUID-
    // WithBytes macro), not a string — compare directly and do not release it.
    void *result = NULL;
    if (CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID)) {
        result = gDriverRef;
    }
    return result;
}

static HRESULT QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface) {
    if (inDriver != gDriverRef || outInterface == NULL) {
        return kAudioHardwareBadObjectError;
    }
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    // IUnknown's UUID and kAudioServerPlugInDriverInterfaceUUID are both constant
    // CFUUIDRefs — use directly, never release.
    CFUUIDRef iUnknown = CFUUIDGetConstantUUIDWithBytes(NULL,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46);
    HRESULT theAnswer = E_NOINTERFACE;
    if (requested != NULL &&
        (CFEqual(requested, iUnknown) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID))) {
        pthread_mutex_lock(&gStateMutex);
        ++gRefCount;
        pthread_mutex_unlock(&gStateMutex);
        *outInterface = gDriverRef;
        theAnswer = S_OK;
    }
    if (requested != NULL) { CFRelease(requested); }
    return theAnswer;
}

static ULONG AddRef(void *inDriver) {
    if (inDriver != gDriverRef) { return 0; }
    pthread_mutex_lock(&gStateMutex);
    if (gRefCount < UINT32_MAX) { ++gRefCount; }
    ULONG value = gRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return value;
}

static ULONG Release(void *inDriver) {
    if (inDriver != gDriverRef) { return 0; }
    pthread_mutex_lock(&gStateMutex);
    if (gRefCount > 0) { --gRefCount; }
    ULONG value = gRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return value; // singleton: never actually freed
}

// MARK: - Lifecycle

static OSStatus Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    if (inDriver != gDriverRef) { return kAudioHardwareBadObjectError; }
    LEMUR_LOG_INIT();
    gPlugInHost = inHost;

    struct mach_timebase_info tb;
    mach_timebase_info(&tb);
    // mach_absolute_time ticks per second = (denom / numer) * 1e9.
    double ticksPerSecond = ((double)tb.denom / (double)tb.numer) * 1.0e9;
    gHostTicksPerFrame = ticksPerSecond / gSampleRate;
    os_log(gLog, "Initialize: hostTicksPerFrame=%{public}.3f", gHostTicksPerFrame);
    return noErr;
}

static OSStatus CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription,
                             const AudioServerPlugInClientInfo *inClientInfo, AudioObjectID *outDeviceObjectID) {
    (void)inDriver; (void)inDescription; (void)inClientInfo; (void)outDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError; // device is static
}

static OSStatus DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID) {
    (void)inDriver; (void)inDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                const AudioServerPlugInClientInfo *inClientInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inClientInfo;
    return noErr;
}

static OSStatus RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                   const AudioServerPlugInClientInfo *inClientInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inClientInfo;
    return noErr;
}

static OSStatus PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                                 UInt64 inChangeAction, void *inChangeInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inChangeAction; (void)inChangeInfo;
    return noErr; // only one format/rate is supported, nothing to reconfigure
}

static OSStatus AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                               UInt64 inChangeAction, void *inChangeInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inChangeAction; (void)inChangeInfo;
    return noErr;
}

// MARK: - Property dispatch

static Boolean HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID,
                           const AudioObjectPropertyAddress *inAddress) {
    (void)inDriver; (void)inClientPID;
    if (inAddress == NULL) { return false; }
    UInt32 size = 0;
    OSStatus status = GetPropertyDataSize(inDriver, inObjectID, inClientPID, inAddress, 0, NULL, &size);
    return status == noErr;
}

static OSStatus IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID,
                                   const AudioObjectPropertyAddress *inAddress, Boolean *outIsSettable) {
    (void)inDriver; (void)inClientPID;
    if (inAddress == NULL || outIsSettable == NULL) { return kAudioHardwareIllegalOperationError; }
    Boolean settable = false;
    if (inObjectID == kObjectID_Device) {
        settable = (inAddress->mSelector == kAudioDevicePropertyNominalSampleRate);
    } else if (inObjectID == kObjectID_Stream_Input) {
        switch (inAddress->mSelector) {
            case kAudioStreamPropertyIsActive:
            case kAudioStreamPropertyVirtualFormat:
            case kAudioStreamPropertyPhysicalFormat:
                settable = true;
                break;
            default:
                settable = false;
                break;
        }
    }
    *outIsSettable = settable;
    return noErr;
}

static OSStatus GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID,
                                    const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize,
                                    const void *inQualifierData, UInt32 *outDataSize) {
    (void)inDriver; (void)inClientPID; (void)inQualifierDataSize; (void)inQualifierData;
    if (inAddress == NULL || outDataSize == NULL) { return kAudioHardwareIllegalOperationError; }

    switch (inObjectID) {
        case kObjectID_PlugIn:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                    *outDataSize = sizeof(AudioObjectID); return noErr;
                case kAudioObjectPropertyManufacturer:
                case kAudioPlugInPropertyResourceBundle:
                    *outDataSize = sizeof(CFStringRef); return noErr;
                case kAudioObjectPropertyOwnedObjects:
                case kAudioPlugInPropertyDeviceList:
                    *outDataSize = sizeof(AudioObjectID); return noErr; // one device
                case kAudioPlugInPropertyTranslateUIDToDevice:
                    *outDataSize = sizeof(AudioObjectID); return noErr;
                default: return kAudioHardwareUnknownPropertyError;
            }
        case kObjectID_Device:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                    *outDataSize = sizeof(AudioObjectID); return noErr;
                case kAudioObjectPropertyName:
                case kAudioObjectPropertyManufacturer:
                case kAudioDevicePropertyDeviceUID:
                case kAudioDevicePropertyModelUID:
                    *outDataSize = sizeof(CFStringRef); return noErr;
                case kAudioObjectPropertyOwnedObjects:
                case kAudioDevicePropertyStreams:
                    // input/global scope expose the one stream, output scope none
                    if (inAddress->mScope == kAudioObjectPropertyScopeOutput) { *outDataSize = 0; }
                    else { *outDataSize = sizeof(AudioObjectID); }
                    return noErr;
                case kAudioObjectPropertyControlList:
                    *outDataSize = 0; return noErr;
                case kAudioDevicePropertyTransportType:
                case kAudioDevicePropertyClockDomain:
                case kAudioDevicePropertyDeviceIsAlive:
                case kAudioDevicePropertyDeviceIsRunning:
                case kAudioDevicePropertyDeviceCanBeDefaultDevice:
                case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
                case kAudioDevicePropertyLatency:
                case kAudioDevicePropertySafetyOffset:
                case kAudioDevicePropertyZeroTimeStampPeriod:
                case kAudioDevicePropertyIsHidden:
                    *outDataSize = sizeof(UInt32); return noErr;
                case kAudioDevicePropertyRelatedDevices:
                    *outDataSize = sizeof(AudioObjectID); return noErr;
                case kAudioDevicePropertyNominalSampleRate:
                    *outDataSize = sizeof(Float64); return noErr;
                case kAudioDevicePropertyAvailableNominalSampleRates:
                    *outDataSize = sizeof(AudioValueRange); return noErr;
                case kAudioDevicePropertyPreferredChannelsForStereo:
                    *outDataSize = 2 * sizeof(UInt32); return noErr;
                case kAudioDevicePropertyPreferredChannelLayout:
                    *outDataSize = offsetof(AudioChannelLayout, mChannelDescriptions) +
                                   (LEMUR_AUDIO_CHANNELS * sizeof(AudioChannelDescription));
                    return noErr;
                default: return kAudioHardwareUnknownPropertyError;
            }
        case kObjectID_Stream_Input:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                    *outDataSize = sizeof(AudioObjectID); return noErr;
                case kAudioObjectPropertyOwnedObjects:
                    *outDataSize = 0; return noErr;
                case kAudioStreamPropertyIsActive:
                case kAudioStreamPropertyDirection:
                case kAudioStreamPropertyTerminalType:
                case kAudioStreamPropertyStartingChannel:
                case kAudioStreamPropertyLatency:
                    *outDataSize = sizeof(UInt32); return noErr;
                case kAudioStreamPropertyVirtualFormat:
                case kAudioStreamPropertyPhysicalFormat:
                    *outDataSize = sizeof(AudioStreamBasicDescription); return noErr;
                case kAudioStreamPropertyAvailableVirtualFormats:
                case kAudioStreamPropertyAvailablePhysicalFormats:
                    *outDataSize = sizeof(AudioStreamRangedDescription); return noErr;
                default: return kAudioHardwareUnknownPropertyError;
            }
        default:
            return kAudioHardwareBadObjectError;
    }
}

// Guarded fixed-size property write: refuse an undersized client buffer rather
// than overflow it, then write the value and report its size. The HAL sizes
// requests from GetPropertyDataSize, so this is defensive — but it keeps a
// malformed request from corrupting memory. Used only inside GetPropertyData
// (it references that function's inDataSize/outData/outDataSize); #undef'd after.
#define LEMUR_WRITE_SCALAR(TYPE, VALUE) do { \
    if (inDataSize < sizeof(TYPE)) { return kAudioHardwareBadPropertySizeError; } \
    *((TYPE *)outData) = (VALUE); \
    *outDataSize = (UInt32)sizeof(TYPE); \
    return noErr; \
} while (0)

static OSStatus GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID,
                                const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize,
                                const void *inQualifierData, UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
    (void)inDriver; (void)inClientPID;
    if (inAddress == NULL || outDataSize == NULL || outData == NULL) {
        return kAudioHardwareIllegalOperationError;
    }

    switch (inObjectID) {
        case kObjectID_PlugIn:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                    LEMUR_WRITE_SCALAR(AudioClassID, kAudioObjectClassID);
                case kAudioObjectPropertyClass:
                    LEMUR_WRITE_SCALAR(AudioClassID, kAudioPlugInClassID);
                case kAudioObjectPropertyOwner:
                    LEMUR_WRITE_SCALAR(AudioObjectID, kAudioObjectUnknown);
                case kAudioObjectPropertyManufacturer:
                    LEMUR_WRITE_SCALAR(CFStringRef, CFSTR(LEMUR_AUDIO_MANUFACTURER));
                case kAudioPlugInPropertyResourceBundle:
                    LEMUR_WRITE_SCALAR(CFStringRef, CFSTR(""));
                case kAudioObjectPropertyOwnedObjects:
                case kAudioPlugInPropertyDeviceList:
                    if (inDataSize >= sizeof(AudioObjectID)) {
                        *((AudioObjectID *)outData) = kObjectID_Device;
                        *outDataSize = sizeof(AudioObjectID);
                    } else {
                        *outDataSize = 0;
                    }
                    return noErr;
                case kAudioPlugInPropertyTranslateUIDToDevice: {
                    AudioObjectID match = kAudioObjectUnknown;
                    if (inQualifierDataSize == sizeof(CFStringRef) && inQualifierData != NULL) {
                        CFStringRef uid = *((const CFStringRef *)inQualifierData);
                        if (uid != NULL && CFStringCompare(uid, CFSTR(LEMUR_AUDIO_DEVICE_UID), 0) == kCFCompareEqualTo) {
                            match = kObjectID_Device;
                        }
                    }
                    LEMUR_WRITE_SCALAR(AudioObjectID, match);
                }
                default: return kAudioHardwareUnknownPropertyError;
            }

        case kObjectID_Device:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                    LEMUR_WRITE_SCALAR(AudioClassID, kAudioObjectClassID);
                case kAudioObjectPropertyClass:
                    LEMUR_WRITE_SCALAR(AudioClassID, kAudioDeviceClassID);
                case kAudioObjectPropertyOwner:
                    LEMUR_WRITE_SCALAR(AudioObjectID, kObjectID_PlugIn);
                case kAudioObjectPropertyName:
                    LEMUR_WRITE_SCALAR(CFStringRef, CFSTR(LEMUR_AUDIO_DEVICE_NAME));
                case kAudioObjectPropertyManufacturer:
                    LEMUR_WRITE_SCALAR(CFStringRef, CFSTR(LEMUR_AUDIO_MANUFACTURER));
                case kAudioDevicePropertyDeviceUID:
                    LEMUR_WRITE_SCALAR(CFStringRef, CFSTR(LEMUR_AUDIO_DEVICE_UID));
                case kAudioDevicePropertyModelUID:
                    LEMUR_WRITE_SCALAR(CFStringRef, CFSTR(kDevice_ModelUID));
                case kAudioObjectPropertyOwnedObjects:
                case kAudioDevicePropertyStreams:
                    if (inAddress->mScope == kAudioObjectPropertyScopeOutput) {
                        *outDataSize = 0;
                    } else if (inDataSize >= sizeof(AudioObjectID)) {
                        *((AudioObjectID *)outData) = kObjectID_Stream_Input;
                        *outDataSize = sizeof(AudioObjectID);
                    } else {
                        *outDataSize = 0;
                    }
                    return noErr;
                case kAudioObjectPropertyControlList:
                    *outDataSize = 0; return noErr;
                case kAudioDevicePropertyTransportType:
                    LEMUR_WRITE_SCALAR(UInt32, kAudioDeviceTransportTypeVirtual);
                case kAudioDevicePropertyRelatedDevices:
                    if (inDataSize >= sizeof(AudioObjectID)) {
                        *((AudioObjectID *)outData) = kObjectID_Device;
                        *outDataSize = sizeof(AudioObjectID);
                    } else {
                        *outDataSize = 0;
                    }
                    return noErr;
                case kAudioDevicePropertyClockDomain:
                    LEMUR_WRITE_SCALAR(UInt32, 0);
                case kAudioDevicePropertyDeviceIsAlive:
                    LEMUR_WRITE_SCALAR(UInt32, 1);
                case kAudioDevicePropertyDeviceIsRunning: {
                    pthread_mutex_lock(&gStateMutex);
                    UInt32 running = (gIOCount > 0) ? 1 : 0;
                    pthread_mutex_unlock(&gStateMutex);
                    LEMUR_WRITE_SCALAR(UInt32, running);
                }
                case kAudioDevicePropertyDeviceCanBeDefaultDevice:
                case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
                    LEMUR_WRITE_SCALAR(UInt32, 1);
                case kAudioDevicePropertyLatency:
                    LEMUR_WRITE_SCALAR(UInt32, 0);
                case kAudioDevicePropertySafetyOffset:
                    LEMUR_WRITE_SCALAR(UInt32, kDevice_SafetyOffset);
                case kAudioDevicePropertyZeroTimeStampPeriod:
                    LEMUR_WRITE_SCALAR(UInt32, kDevice_ZeroTimeStampPeriod);
                case kAudioDevicePropertyIsHidden:
                    LEMUR_WRITE_SCALAR(UInt32, 0);
                case kAudioDevicePropertyNominalSampleRate:
                    LEMUR_WRITE_SCALAR(Float64, gSampleRate);
                case kAudioDevicePropertyAvailableNominalSampleRates: {
                    AudioValueRange range = { gSampleRate, gSampleRate };
                    LEMUR_WRITE_SCALAR(AudioValueRange, range);
                }
                case kAudioDevicePropertyPreferredChannelsForStereo:
                    if (inDataSize >= 2 * sizeof(UInt32)) {
                        ((UInt32 *)outData)[0] = 1;
                        ((UInt32 *)outData)[1] = 2;
                        *outDataSize = 2 * sizeof(UInt32);
                    } else {
                        *outDataSize = 0;
                    }
                    return noErr;
                case kAudioDevicePropertyPreferredChannelLayout: {
                    UInt32 needed = (UInt32)(offsetof(AudioChannelLayout, mChannelDescriptions) +
                                             (LEMUR_AUDIO_CHANNELS * sizeof(AudioChannelDescription)));
                    if (inDataSize < needed) { *outDataSize = 0; return noErr; }
                    AudioChannelLayout *layout = (AudioChannelLayout *)outData;
                    memset(layout, 0, needed);
                    layout->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
                    layout->mNumberChannelDescriptions = LEMUR_AUDIO_CHANNELS;
                    layout->mChannelDescriptions[0].mChannelLabel = kAudioChannelLabel_Left;
                    layout->mChannelDescriptions[1].mChannelLabel = kAudioChannelLabel_Right;
                    *outDataSize = needed;
                    return noErr;
                }
                default: return kAudioHardwareUnknownPropertyError;
            }

        case kObjectID_Stream_Input:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                    LEMUR_WRITE_SCALAR(AudioClassID, kAudioObjectClassID);
                case kAudioObjectPropertyClass:
                    LEMUR_WRITE_SCALAR(AudioClassID, kAudioStreamClassID);
                case kAudioObjectPropertyOwner:
                    LEMUR_WRITE_SCALAR(AudioObjectID, kObjectID_Device);
                case kAudioObjectPropertyOwnedObjects:
                    *outDataSize = 0; return noErr;
                case kAudioStreamPropertyIsActive: {
                    pthread_mutex_lock(&gStateMutex);
                    UInt32 active = gStreamIsActive ? 1 : 0;
                    pthread_mutex_unlock(&gStateMutex);
                    LEMUR_WRITE_SCALAR(UInt32, active);
                }
                case kAudioStreamPropertyDirection:
                    LEMUR_WRITE_SCALAR(UInt32, 1); // 1 = input
                case kAudioStreamPropertyTerminalType:
                    LEMUR_WRITE_SCALAR(UInt32, kAudioStreamTerminalTypeMicrophone);
                case kAudioStreamPropertyStartingChannel:
                    LEMUR_WRITE_SCALAR(UInt32, 1);
                case kAudioStreamPropertyLatency:
                    LEMUR_WRITE_SCALAR(UInt32, 0);
                case kAudioStreamPropertyVirtualFormat:
                case kAudioStreamPropertyPhysicalFormat:
                    if (inDataSize < sizeof(AudioStreamBasicDescription)) { return kAudioHardwareBadPropertySizeError; }
                    FillFormat((AudioStreamBasicDescription *)outData);
                    *outDataSize = sizeof(AudioStreamBasicDescription); return noErr;
                case kAudioStreamPropertyAvailableVirtualFormats:
                case kAudioStreamPropertyAvailablePhysicalFormats: {
                    if (inDataSize < sizeof(AudioStreamRangedDescription)) { return kAudioHardwareBadPropertySizeError; }
                    AudioStreamRangedDescription desc;
                    memset(&desc, 0, sizeof(desc));
                    FillFormat(&desc.mFormat);
                    desc.mSampleRateRange.mMinimum = gSampleRate;
                    desc.mSampleRateRange.mMaximum = gSampleRate;
                    *((AudioStreamRangedDescription *)outData) = desc;
                    *outDataSize = sizeof(AudioStreamRangedDescription); return noErr;
                }
                default: return kAudioHardwareUnknownPropertyError;
            }

        default:
            return kAudioHardwareBadObjectError;
    }
}

#undef LEMUR_WRITE_SCALAR

static OSStatus SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID,
                                const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize,
                                const void *inQualifierData, UInt32 inDataSize, const void *inData) {
    (void)inDriver; (void)inClientPID; (void)inQualifierDataSize; (void)inQualifierData;
    if (inAddress == NULL || inData == NULL) { return kAudioHardwareIllegalOperationError; }

    if (inObjectID == kObjectID_Device) {
        if (inAddress->mSelector == kAudioDevicePropertyNominalSampleRate) {
            if (inDataSize < sizeof(Float64)) { return kAudioHardwareBadPropertySizeError; }
            Float64 requested = *((const Float64 *)inData);
            return (requested == gSampleRate) ? noErr : kAudioHardwareIllegalOperationError;
        }
        return kAudioHardwareUnknownPropertyError;
    }

    if (inObjectID == kObjectID_Stream_Input) {
        switch (inAddress->mSelector) {
            case kAudioStreamPropertyIsActive: {
                if (inDataSize < sizeof(UInt32)) { return kAudioHardwareBadPropertySizeError; }
                pthread_mutex_lock(&gStateMutex);
                gStreamIsActive = (*((const UInt32 *)inData) != 0);
                pthread_mutex_unlock(&gStateMutex);
                return noErr;
            }
            case kAudioStreamPropertyVirtualFormat:
            case kAudioStreamPropertyPhysicalFormat: {
                if (inDataSize < sizeof(AudioStreamBasicDescription)) { return kAudioHardwareBadPropertySizeError; }
                const AudioStreamBasicDescription *f = (const AudioStreamBasicDescription *)inData;
                AudioStreamBasicDescription ours;
                FillFormat(&ours);
                if (f->mSampleRate == ours.mSampleRate && f->mFormatID == ours.mFormatID &&
                    f->mChannelsPerFrame == ours.mChannelsPerFrame && f->mBitsPerChannel == ours.mBitsPerChannel) {
                    return noErr; // matches the only format we support
                }
                return kAudioDeviceUnsupportedFormatError;
            }
            default:
                return kAudioHardwareUnknownPropertyError;
        }
    }

    return kAudioHardwareBadObjectError;
}

// MARK: - IO

static OSStatus StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    (void)inClientID;
    if (inDriver != gDriverRef) { return kAudioHardwareBadObjectError; }
    if (inDeviceObjectID != kObjectID_Device) { return kAudioHardwareBadObjectError; }

    pthread_mutex_lock(&gStateMutex);
    Boolean firstStart = (gIOCount == 0);
    if (firstStart) {
        // EnsureRingMapped drops any stale backlog before publishing the pointer.
        // If the region does not exist yet (e.g. the app has not launched since
        // boot), retry off the real-time path so audio begins as soon as the app
        // creates it — without this, the pointer would stay NULL for the whole IO
        // session and the device would be silent until the consumer restarted it.
        if (!EnsureRingMapped()) {
            StartRingMapRetry();
        }
        gAnchorHostTime = mach_absolute_time();
        gNumberTimeStamps = 0;
    }
    ++gIOCount;
    pthread_mutex_unlock(&gStateMutex);

    if (firstStart) {
        os_log(gLog, "StartIO — first client, posting consumerStarted");
        PostDarwinNotification(LEMUR_AUDIO_NOTIFY_CONSUMER_STARTED);
    }
    return noErr;
}

static OSStatus StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    (void)inClientID;
    if (inDriver != gDriverRef) { return kAudioHardwareBadObjectError; }
    if (inDeviceObjectID != kObjectID_Device) { return kAudioHardwareBadObjectError; }

    pthread_mutex_lock(&gStateMutex);
    if (gIOCount > 0) { --gIOCount; }
    Boolean lastStop = (gIOCount == 0);
    pthread_mutex_unlock(&gStateMutex);

    if (lastStop) {
        os_log(gLog, "StopIO — last client, posting consumerStopped");
        PostDarwinNotification(LEMUR_AUDIO_NOTIFY_CONSUMER_STOPPED);
    }
    return noErr;
}

static OSStatus GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                 Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed) {
    (void)inClientID;
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) { return kAudioHardwareBadObjectError; }
    if (outSampleTime == NULL || outHostTime == NULL || outSeed == NULL) { return kAudioHardwareIllegalOperationError; }

    UInt64 now = mach_absolute_time();
    Float64 ticksPerPeriod = gHostTicksPerFrame * (Float64)kDevice_ZeroTimeStampPeriod;
    if (gAnchorHostTime == 0) { gAnchorHostTime = now; }

    // Advance the timeline by however many whole periods have elapsed since the
    // anchor, not just one. A single ++ per call silently lags real time if the
    // IO thread is ever starved long enough to miss a period boundary; catching
    // up keeps the reported sample time aligned with the host clock.
    for (;;) {
        Float64 nextOffset = ((Float64)(gNumberTimeStamps + 1)) * ticksPerPeriod;
        UInt64 nextHostTime = gAnchorHostTime + (UInt64)nextOffset;
        if (now < nextHostTime) { break; }
        ++gNumberTimeStamps;
    }

    *outSampleTime = (Float64)(gNumberTimeStamps * kDevice_ZeroTimeStampPeriod);
    *outHostTime = gAnchorHostTime + (UInt64)(((Float64)gNumberTimeStamps) * ticksPerPeriod);
    *outSeed = 1;
    return noErr;
}

static OSStatus WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                  UInt32 inOperationID, Boolean *outWillDo, Boolean *outWillDoInPlace) {
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID;
    Boolean willDo = false;
    Boolean willDoInPlace = true;
    if (inOperationID == kAudioServerPlugInIOOperationReadInput) {
        willDo = true;
        willDoInPlace = true;
    }
    if (outWillDo != NULL) { *outWillDo = willDo; }
    if (outWillDoInPlace != NULL) { *outWillDoInPlace = willDoInPlace; }
    return noErr;
}

static OSStatus BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                 UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                 const AudioServerPlugInIOCycleInfo *inIOCycleInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID;
    (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    return noErr;
}

static OSStatus DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                              AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID,
                              UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo,
                              void *ioMainBuffer, void *ioSecondaryBuffer) {
    (void)inDriver; (void)inDeviceObjectID; (void)inStreamObjectID; (void)inClientID;
    (void)inIOCycleInfo; (void)ioSecondaryBuffer;

    if (inOperationID == kAudioServerPlugInIOOperationReadInput && ioMainBuffer != NULL) {
        float *dst = (float *)ioMainBuffer;
        // Read the published pointer once (acquire); pairs with StartIO's release
        // store. Lock-free and allocation-free — safe on the real-time thread.
        LemurAudioRing *ring = atomic_load_explicit(&gRing, memory_order_acquire);
        if (ring != NULL && lemur_ring_ready(ring)) {
            lemur_ring_read(ring, dst, inIOBufferFrameSize); // zero-fills underrun
        } else {
            memset(dst, 0, (size_t)inIOBufferFrameSize * LEMUR_AUDIO_BYTES_PER_FRAME);
        }
    }
    return noErr;
}

static OSStatus EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                               UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                               const AudioServerPlugInIOCycleInfo *inIOCycleInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID;
    (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    return noErr;
}

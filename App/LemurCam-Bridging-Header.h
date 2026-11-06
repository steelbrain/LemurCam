//
//  LemurCam-Bridging-Header.h
//
//  Exposes the C audio ring-buffer contract to the app's Swift code, plus a
//  shm_open shim. shm_open is variadic in C (the mode is passed via `...`), which
//  Swift cannot call directly, so we wrap the create form here. The driver's
//  consumer-signal and ring-map retry helpers are here for the unit tests.
//

#import "LemurAudioConsumerSignal.h"
#import "LemurAudioRingMapRetry.h"
#import "LemurAudioShared.h"

#import <errno.h>
#import <fcntl.h>
#import <sys/mman.h>
#import <sys/stat.h>
#import <unistd.h>

/// Create/open the producer's shared-memory region so the consumer — the driver
/// running inside `coreaudiod` under a *different* uid (`_coreaudiod`) — can map
/// it read-write. macOS-specific rules drive the shape of this:
///
///   * A POSIX shm object may be `ftruncate`d only once, at creation; calling it
///     again on an already-sized region fails with EINVAL. We create with O_EXCL
///     to learn whether we own initialisation and size it only on that path.
///   * The caller must not trust an existing region: anyone can create this name
///     first. Check it with `lemur_shm_check_stat` before mapping.
///   * The 0666 mode is what lets `_coreaudiod` open the region. On macOS 27 the
///     mode is applied as given (a 077 umask still yields 0666) and `fchmod` on a
///     shm descriptor always fails with EINVAL, so an existing region's mode
///     cannot be repaired. `lemur_shm_check_stat` reports a region the driver
///     cannot open instead of assuming the mode took.
static inline int lemur_shm_open_create(const char *name) {
    int fd = shm_open(name, O_CREAT | O_EXCL | O_RDWR, 0666);
    if (fd >= 0) {
        if (ftruncate(fd, (off_t)sizeof(LemurAudioRing)) != 0) {
            int savedErrno = errno;
            close(fd);
            shm_unlink(name);
            errno = savedErrno;
            return -1;
        }
        return fd;
    }
    if (errno != EEXIST) { return -1; }
    return shm_open(name, O_RDWR, 0);
}

/// Verdicts of `lemur_shm_check_stat`.
#define LEMUR_SHM_REGION_OK 0
/// Owned by another user: refuse it. Another account created the name first (or
/// the region is left over from a different user's session) and could read or
/// rewrite everything the app writes into it.
#define LEMUR_SHM_REGION_FOREIGN_OWNER 1
/// Smaller than the ring (mapping it would fault past the end of the object) or
/// far larger than this build's layout: refuse it.
#define LEMUR_SHM_REGION_BAD_SIZE 2
/// Usable by the app, but its mode does not grant read-write to others, so the
/// driver (running as `_coreaudiod`) cannot open it and the mic stays silent.
/// Not a safety problem; worth a log line.
#define LEMUR_SHM_REGION_DRIVER_CANNOT_OPEN 3

/// Largest object size accepted for a region holding one `LemurAudioRing`: the
/// kernel rounds a shm object up to whole pages, so allow rounding up to 64 KiB
/// (covers 4 KiB and 16 KiB pages, including a Rosetta process whose page size
/// differs from the kernel's).
static inline off_t lemur_shm_max_region_size(size_t mapSize) {
    const size_t granule = 65536;
    return (off_t)((mapSize + granule - 1) / granule * granule);
}

/// Validate an opened region before mapping `mapSize` bytes of it. Pure function
/// of the `fstat` result so the policy is unit-testable without real shm.
static inline int lemur_shm_check_stat(const struct stat *st, uid_t expectedOwner, size_t mapSize) {
    if (st->st_uid != expectedOwner) { return LEMUR_SHM_REGION_FOREIGN_OWNER; }
    if (st->st_size < (off_t)mapSize || st->st_size > lemur_shm_max_region_size(mapSize)) {
        return LEMUR_SHM_REGION_BAD_SIZE;
    }
    if ((st->st_mode & 0666) != 0666) { return LEMUR_SHM_REGION_DRIVER_CANNOT_OPEN; }
    return LEMUR_SHM_REGION_OK;
}

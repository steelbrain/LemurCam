//
//  LemurCam-Bridging-Header.h
//
//  Exposes the C audio ring-buffer contract to the app's Swift code, plus a
//  shm_open shim. shm_open is variadic in C (the mode is passed via `...`), which
//  Swift cannot call directly, so we wrap the create form here.
//

#import "LemurAudioShared.h"

#import <errno.h>
#import <fcntl.h>
#import <sys/mman.h>
#import <sys/stat.h>
#import <unistd.h>

/// Create/open the producer's shared-memory region so the consumer — the driver
/// running inside `coreaudiod` under a *different* uid (`_coreaudiod`) — can map
/// it read-write. Two macOS-specific rules drive the shape of this:
///
///   * A POSIX shm object may be `ftruncate`d only once, at creation; calling it
///     again on an already-sized region fails with EINVAL. We create with O_EXCL
///     to learn whether we own initialisation and size it only on that path.
///   * `shm_open`'s mode is masked by the umask, so 0666 alone yields 0644 (no
///     group/other write). We `fchmod` afterwards to force 0666; the producer
///     owns the region, so this also heals one a prior build left at 0600.
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
    } else {
        if (errno != EEXIST) { return -1; }
        fd = shm_open(name, O_RDWR, 0666);
        if (fd < 0) { return -1; }
    }
    fchmod(fd, 0666);
    return fd;
}

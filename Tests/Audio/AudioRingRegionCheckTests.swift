import Darwin
@testable import LemurCam
import XCTest

/// Covers the checks `AudioRingBuffer.open()` applies to the shm region before mapping
/// it (`lemur_shm_check_stat`). Anyone can create the region's name first, so a region
/// owned by another user or of the wrong size must be refused, and a mode the driver
/// (running as `_coreaudiod`) cannot open must be reported.
internal final class AudioRingRegionCheckTests: XCTestCase {
    private let mapSize = MemoryLayout<LemurAudioRing>.size

    private func stat(uid: uid_t, size: off_t, mode: mode_t = 0o666) -> Darwin.stat {
        var info = Darwin.stat()
        info.st_uid = uid
        info.st_size = size
        info.st_mode = mode
        return info
    }

    func testAcceptsOwnPageRoundedRegion() {
        for size in [mapSize, 135_168, 147_456] { // exact, 4 KiB pages, 16 KiB pages
            var info = stat(uid: geteuid(), size: off_t(size))
            XCTAssertEqual(lemur_shm_check_stat(&info, geteuid(), mapSize), LEMUR_SHM_REGION_OK, "size \(size)")
        }
    }

    func testRefusesForeignOwner() {
        var foreign = stat(uid: geteuid() &+ 1, size: off_t(mapSize))
        XCTAssertEqual(lemur_shm_check_stat(&foreign, geteuid(), mapSize), LEMUR_SHM_REGION_FOREIGN_OWNER)
    }

    func testRefusesShortOrOversizedRegion() {
        // A short object would fault when the ring's tail is touched; a much larger one
        // belongs to a different layout.
        for size in [0, mapSize - 1, mapSize * 4] {
            var info = stat(uid: geteuid(), size: off_t(size))
            XCTAssertEqual(lemur_shm_check_stat(&info, geteuid(), mapSize), LEMUR_SHM_REGION_BAD_SIZE, "size \(size)")
        }
    }

    func testFlagsModeTheDriverCannotOpen() {
        for mode: mode_t in [0o600, 0o644, 0o660] {
            var info = stat(uid: geteuid(), size: off_t(mapSize), mode: mode)
            XCTAssertEqual(
                lemur_shm_check_stat(&info, geteuid(), mapSize), LEMUR_SHM_REGION_DRIVER_CANNOT_OPEN,
                "mode \(String(mode, radix: 8))"
            )
        }
    }

    func testRegionTheAppCreatesPassesTheCheck() {
        let name = "/lemur.t.\(getpid()).\(UInt16.random(in: 0...UInt16.max))"
        defer { shm_unlink(name) }
        let buffer = AudioRingBuffer(name: name)
        XCTAssertTrue(buffer.open())

        let descriptor = lemur_shm_open_create(name)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }
        var info = Darwin.stat()
        XCTAssertEqual(fstat(descriptor, &info), 0)
        XCTAssertEqual(
            lemur_shm_check_stat(&info, geteuid(), mapSize), LEMUR_SHM_REGION_OK,
            "the region the app creates must be owned by it, ring-sized, and openable by the driver's uid"
        )
    }
}

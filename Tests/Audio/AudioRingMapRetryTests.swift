// This import brings in the app's bridging header (the driver's C ring-map helpers), a use the analyzer misses.
// swiftlint:disable:next unused_import
@testable import LemurCam
import XCTest

/// The driver mapped the app's audio ring only on the first client's StartIO, and
/// its retry gave up after 60 attempts a second apart. After a reboot the region
/// does not exist until the app runs, so a call that started recording from the
/// microphone more than a minute before the app was opened stayed silent until
/// every client stopped. The driver now maps on any StartIO that finds no ring
/// mapped, and retries for as long as a client runs IO. These drive the
/// decisions in `LemurAudioRingMapRetry.h` the way the driver does under its lock.
internal final class AudioRingMapRetryTests: XCTestCase {
    func testTheRingIsWantedOnlyWhileAClientRunsAndNoneIsMapped() {
        XCTAssertTrue(lemur_audio_ring_map_wanted(1, false))
        XCTAssertTrue(lemur_audio_ring_map_wanted(2, false), "a later client maps too, not only the first")
        XCTAssertTrue(lemur_audio_ring_map_wanted(UInt32.max, false))
        XCTAssertFalse(lemur_audio_ring_map_wanted(0, false), "no client: nothing to map for")
        XCTAssertFalse(lemur_audio_ring_map_wanted(1, true))
        XCTAssertFalse(lemur_audio_ring_map_wanted(0, true))
    }

    /// The reported case: after a reboot a call records from the microphone, the
    /// user opens LemurCam 90 s later, and the retry still running maps the ring on
    /// its next attempt.
    func testARingTheAppCreatesLongAfterTheCallStartedIsMapped() {
        var driver = RingMapDriverModel()
        driver.startIO()
        XCTAssertFalse(driver.ringMapped)
        XCTAssertTrue(driver.retryThreadAlive)

        driver.runRetry(seconds: 90)
        XCTAssertTrue(driver.retryThreadAlive, "still retrying after 90 s")
        XCTAssertFalse(driver.ringMapped)

        driver.regionExists = true
        driver.runRetry(seconds: 1)
        XCTAssertTrue(driver.ringMapped)
        XCTAssertFalse(driver.retryThreadAlive, "the retry stops once the ring is mapped")
        XCTAssertFalse(driver.retryRunning)
        XCTAssertEqual(driver.retryThreadsStarted, 1)
    }

    /// No cap: an hour of failed attempts while the client records keeps the retry
    /// going.
    func testTheRetryKeepsGoingForAsLongAsAClientRuns() {
        var driver = RingMapDriverModel()
        driver.startIO()

        driver.runRetry(seconds: 3600)
        XCTAssertTrue(driver.retryThreadAlive)
        XCTAssertTrue(driver.retryRunning)

        driver.regionExists = true
        driver.runRetry(seconds: 1)
        XCTAssertTrue(driver.ringMapped)
    }

    func testTheRetryStopsOnceNoClientRunsIO() {
        var driver = RingMapDriverModel()
        driver.startIO()
        driver.runRetry(seconds: 5)
        driver.stopIO()

        driver.runRetry(seconds: 1)
        XCTAssertFalse(driver.retryThreadAlive)
        XCTAssertFalse(driver.retryRunning)
        XCTAssertFalse(driver.ringMapped)

        driver.regionExists = true
        driver.runRetry(seconds: 5)
        XCTAssertFalse(driver.ringMapped, "nothing maps with no client")
    }

    /// Clients that start while a retry runs leave it to that retry.
    func testOnlyOneRetryRunsHoweverManyClientsStart() {
        var driver = RingMapDriverModel()
        driver.startIO()
        driver.runRetry(seconds: 2)
        driver.startIO()
        driver.startIO()

        XCTAssertEqual(driver.ioCount, 3)
        XCTAssertEqual(driver.retryThreadsStarted, 1)
    }

    /// The retry gives up its claim in the same lock hold as its decision to stop,
    /// so a client that starts right after it starts a new retry instead of finding
    /// the old one's claim and counting on a thread that is exiting.
    func testAClientStartingRightAfterTheRetryStoppedStartsANewOne() {
        var driver = RingMapDriverModel()
        driver.startIO()
        driver.stopIO()
        driver.runRetry(seconds: 1)
        XCTAssertFalse(driver.retryThreadAlive)

        driver.startIO()
        XCTAssertEqual(driver.retryThreadsStarted, 2)
        XCTAssertTrue(driver.retryThreadAlive)

        driver.regionExists = true
        driver.runRetry(seconds: 1)
        XCTAssertTrue(driver.ringMapped)
    }

    /// With no retry running (its thread could not be created), a later client's
    /// StartIO maps the ring: only the first client's used to.
    func testALaterClientMapsTheRingWhenNoRetryRuns() {
        var driver = RingMapDriverModel()
        driver.retryThreadCanStart = false
        driver.startIO()
        XCTAssertFalse(driver.retryThreadAlive)
        XCTAssertFalse(driver.retryRunning, "a thread that could not start releases its claim")

        driver.regionExists = true
        driver.startIO()
        XCTAssertTrue(driver.ringMapped)
    }

    /// A mapped ring is never mapped again, and starts no retry.
    func testAMappedRingStartsNoRetry() {
        var driver = RingMapDriverModel()
        driver.regionExists = true
        driver.startIO()
        XCTAssertTrue(driver.ringMapped)
        XCTAssertEqual(driver.mapAttempts, 1)

        driver.startIO()
        driver.stopIO()
        driver.stopIO()
        driver.startIO()
        XCTAssertEqual(driver.mapAttempts, 1)
        XCTAssertEqual(driver.retryThreadsStarted, 0)
    }
}

/// The driver's ring-map state as StartIO, StopIO and the retry thread change it
/// under gStateMutex (Audio/LemurCamAudioDriver.c), with `regionExists` standing
/// in for whether shm_open and mmap of the region succeed.
private struct RingMapDriverModel {
    var ioCount: UInt32 = 0
    var ringMapped = false
    var regionExists = false
    /// `gMapRetryRunning`.
    var retryRunning = false
    /// Whether a retry thread is still looping; it ends when an attempt says stop.
    var retryThreadAlive = false
    var retryThreadsStarted = 0
    /// False makes pthread_create fail.
    var retryThreadCanStart = true
    var mapAttempts = 0

    mutating func startIO() {
        _ = lemur_audio_io_started(&ioCount)
        guard lemur_audio_ring_map_wanted(ioCount, ringMapped), !map() else { return }
        guard lemur_audio_ring_map_retry_claim(&retryRunning) else { return }
        if retryThreadCanStart {
            retryThreadsStarted += 1
            retryThreadAlive = true
        } else {
            retryRunning = false
        }
    }

    mutating func stopIO() {
        _ = lemur_audio_io_stopped(&ioCount)
    }

    /// `seconds` wakes of the retry thread, while it runs.
    mutating func runRetry(seconds: Int) {
        for _ in 0..<seconds where retryThreadAlive {
            if lemur_audio_ring_map_wanted(ioCount, ringMapped) {
                _ = map()
            }
            retryThreadAlive = lemur_audio_ring_map_retry_continues(ioCount, ringMapped, &retryRunning)
        }
    }

    private mutating func map() -> Bool {
        mapAttempts += 1
        if regionExists { ringMapped = true }
        return ringMapped
    }
}

@testable import LemurCam
import os
import VideoToolbox
import XCTest

/// Locks the decode-error log dedupe. After packet loss VideoToolbox can fail every
/// frame until the next keyframe with the same status, which used to log one line per
/// frame. A run of identical errors now logs once; a successful decode or a different
/// status starts a new run.
internal final class DecodeErrorDeduperTests: XCTestCase {
    private let referenceMissing = kVTVideoDecoderReferenceMissingErr
    private let badData = kVTVideoDecoderBadDataErr

    func testLogsARunOfIdenticalErrorsOnce() {
        let deduper = DecodeErrorDeduper()

        XCTAssertTrue(deduper.shouldLog(referenceMissing), "the first error of a run must be logged")
        XCTAssertFalse(deduper.shouldLog(referenceMissing), "a repeat of the same error must be suppressed")
        XCTAssertFalse(deduper.shouldLog(referenceMissing), "a repeat of the same error must be suppressed")
    }

    func testSuccessIsNeverLogged() {
        let deduper = DecodeErrorDeduper()

        XCTAssertFalse(deduper.shouldLog(noErr))
    }

    func testSuccessEndsTheRunSoARecurrenceIsLogged() {
        let deduper = DecodeErrorDeduper()
        XCTAssertTrue(deduper.shouldLog(referenceMissing))
        XCTAssertFalse(deduper.shouldLog(referenceMissing))

        XCTAssertFalse(deduper.shouldLog(noErr))

        XCTAssertTrue(deduper.shouldLog(referenceMissing), "the same error after a decoded frame is a new run")
    }

    func testDifferentStatusStartsANewRun() {
        let deduper = DecodeErrorDeduper()
        XCTAssertTrue(deduper.shouldLog(referenceMissing))
        XCTAssertFalse(deduper.shouldLog(referenceMissing))

        XCTAssertTrue(deduper.shouldLog(badData), "a different error must be logged")
        XCTAssertFalse(deduper.shouldLog(badData))
        XCTAssertTrue(deduper.shouldLog(referenceMissing), "switching back is a new run too")
    }

    func testResetLogsTheNextError() {
        let deduper = DecodeErrorDeduper()
        XCTAssertTrue(deduper.shouldLog(referenceMissing))

        deduper.reset()

        XCTAssertTrue(deduper.shouldLog(referenceMissing), "a new decode session must log its first error")
    }

    /// The output handler runs on VideoToolbox's thread while the decode loop submits
    /// frames, so concurrent callers must still see the run logged exactly once.
    func testConcurrentIdenticalErrorsLogOnce() {
        let deduper = DecodeErrorDeduper()
        let logged = OSAllocatedUnfairLock<Int>(initialState: 0)
        let status = referenceMissing

        DispatchQueue.concurrentPerform(iterations: 1000) { _ in
            if deduper.shouldLog(status) {
                logged.withLock { $0 += 1 }
            }
        }

        XCTAssertEqual(logged.withLock { $0 }, 1)
    }
}

import Foundation
@testable import LemurCam
import os
import XCTest

/// Locks the `DualLogger` fan-out contract: every level method forwards the exact
/// (category, level, message) tuple to the process-wide `onEmit` sink that feeds
/// the in-app log view. The level tags ("DEBUG"/"INFO"/"WARN"/"ERROR"/"FAULT")
/// are stable strings the log UI depends on, so pin each one. The os.Logger and
/// stderr writes are side effects we don't assert; the sink tuple is the contract.
internal final class DualLoggerTests: XCTestCase {
    private var savedOnEmit: (@Sendable (String, String, String) -> Void)?
    private let recorder = EventRecorder()

    override func setUp() {
        super.setUp()
        // The real app wires onEmit to LogStore; save and restore around each test
        // so we neither hijack nor drop the running host app's log sink.
        savedOnEmit = DualLogger.onEmit
        recorder.removeAll()
        DualLogger.onEmit = { [recorder] category, level, message in
            recorder.append(category: category, level: level, message: message)
        }
    }

    override func tearDown() {
        DualLogger.onEmit = savedOnEmit
        super.tearDown()
    }

    func testEachLevelForwardsItsTag() {
        let log = DualLogger(subsystem: "cam.lemur.test", category: "unit")
        log.debug("d")
        log.info("i")
        log.warning("w")
        log.error("e")
        log.fault("f")

        let events = recorder.snapshot()
        XCTAssertEqual(events.map(\.level), ["DEBUG", "INFO", "WARN", "ERROR", "FAULT"])
        XCTAssertEqual(events.map(\.message), ["d", "i", "w", "e", "f"])
        XCTAssertTrue(events.allSatisfy { $0.category == "unit" })
    }

    func testCategoryComesFromInitializer() {
        DualLogger(subsystem: "s", category: "alpha").info("x")
        DualLogger(subsystem: "s", category: "beta").info("y")

        let events = recorder.snapshot()
        XCTAssertEqual(events.map(\.category), ["alpha", "beta"])
    }

    func testMessageIsForwardedVerbatim() {
        let message = "value=42 path=/a/b αβ \"quoted\""
        DualLogger(subsystem: "s", category: "c").error(message)

        let events = recorder.snapshot()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.message, message)
    }

    /// With no sink installed, logging still writes to os.Logger/stderr but must
    /// not crash and must capture nothing.
    func testNilSinkDoesNotCrash() {
        DualLogger.onEmit = nil
        DualLogger(subsystem: "s", category: "c").info("no sink")

        XCTAssertTrue(recorder.snapshot().isEmpty)
    }
}

private final class EventRecorder: Sendable {
    typealias Event = (category: String, level: String, message: String)

    private let events = OSAllocatedUnfairLock<[Event]>(initialState: [])

    func append(category: String, level: String, message: String) {
        events.withLock {
            $0.append((category, level, message))
        }
    }

    func snapshot() -> [Event] {
        events.withLock { $0 }
    }

    func removeAll() {
        events.withLock {
            $0.removeAll()
        }
    }
}

@testable import LemurCam
import XCTest

/// Locks how long LemurCam remembers that a stale audio helper serves it. The mark
/// used to live for one app session only, so relaunching the app without
/// restarting the Mac offered Update again, and installing through the same helper
/// cut audio again for nothing. It now lasts until the Mac restarts.
internal final class StaleHelperMarkerTests: XCTestCase {
    private let bootTime = 1_793_763_569_707_672

    func testNothingRecordedIsNotSet() throws {
        let marker = StaleHelperMarker(defaults: try freshDefaults("nothing"), bootTime: { self.bootTime })

        XCTAssertFalse(marker.isSet)
    }

    func testTheMarkHoldsForTheNextLaunchInTheSameBoot() throws {
        let defaults = try freshDefaults("sameBoot")
        StaleHelperMarker(defaults: defaults, bootTime: { self.bootTime }).record()

        // A relaunch of the app reads the mark back from the same defaults.
        let relaunched = StaleHelperMarker(defaults: defaults, bootTime: { self.bootTime })

        XCTAssertTrue(relaunched.isSet)
    }

    func testARestartEndsTheMark() throws {
        let defaults = try freshDefaults("restart")
        StaleHelperMarker(defaults: defaults, bootTime: { self.bootTime }).record()

        let afterRestart = StaleHelperMarker(defaults: defaults, bootTime: { self.bootTime + 600_000_000 })

        XCTAssertFalse(afterRestart.isSet)
    }

    func testAnUnknownBootTimeNeverCounts() throws {
        let defaults = try freshDefaults("unknownBoot")
        StaleHelperMarker(defaults: defaults, bootTime: { nil }).record()
        XCTAssertFalse(StaleHelperMarker(defaults: defaults, bootTime: { self.bootTime }).isSet, "nothing recorded")

        StaleHelperMarker(defaults: defaults, bootTime: { self.bootTime }).record()
        XCTAssertFalse(StaleHelperMarker(defaults: defaults, bootTime: { nil }).isSet)
    }

    /// The real reader returns this Mac's boot time: in the past, and the same on
    /// every read.
    func testTheBootTimeComesFromTheSystem() throws {
        let first = try XCTUnwrap(BootTime.current())
        let nowMicroseconds = Int(Date().timeIntervalSince1970 * 1_000_000)

        XCTAssertGreaterThan(first, 0)
        XCTAssertLessThan(first, nowMicroseconds)
        XCTAssertEqual(BootTime.current(), first)
    }

    private func freshDefaults(_ name: String) throws -> UserDefaults {
        let suite = "StaleHelperMarkerTests.\(name)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}

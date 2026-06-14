@testable import LemurCam
import XCTest

/// Locks the persisted restart-escalation marker: the round-trip that decides
/// whether an app restart was *already* tried for the current bundle version (and
/// therefore a still-stale running version should escalate to a Mac reboot). The
/// pure `escalateIfStuck` decision is tested elsewhere; this pins the persistence
/// and the snapshot-at-init semantics it relies on.
internal final class CameraRestartMarkerTests: XCTestCase {

    func testFreshMarkerHasNoPriorRequest() throws {
        let marker = CameraRestartMarker(defaults: try freshDefaults("fresh"))
        XCTAssertNil(marker.previousRequestedVersion)
        XCTAssertFalse(marker.wasRestartAlreadyTried(forBundled: "5"))
    }

    func testRecordPersistsAcrossInstances() throws {
        let defaults = try freshDefaults("persist")
        CameraRestartMarker(defaults: defaults).record(version: "5")
        // A later launch reads the prior value back as its snapshot.
        let next = CameraRestartMarker(defaults: defaults)
        XCTAssertEqual(next.previousRequestedVersion, "5")
        XCTAssertTrue(next.wasRestartAlreadyTried(forBundled: "5"))
    }

    func testRestartTriedOnlyMatchesSameVersion() throws {
        let defaults = try freshDefaults("version-match")
        CameraRestartMarker(defaults: defaults).record(version: "5")
        let next = CameraRestartMarker(defaults: defaults)
        // A different bundle version (e.g. a fresh upgrade) is a new ask, not a
        // stuck restart — must not escalate to reboot.
        XCTAssertFalse(next.wasRestartAlreadyTried(forBundled: "6"))
        XCTAssertTrue(next.wasRestartAlreadyTried(forBundled: "5"))
    }

    func testSnapshotIgnoresWritesMadeThisLaunch() throws {
        // Recording this launch must not flip *this* instance's decision — the
        // escalation must reflect a prior launch's ask, not our own write.
        let marker = CameraRestartMarker(defaults: try freshDefaults("snapshot"))
        marker.record(version: "5")
        XCTAssertNil(marker.previousRequestedVersion)
        XCTAssertFalse(marker.wasRestartAlreadyTried(forBundled: "5"))
    }

    func testClearRemovesTheMarker() throws {
        let defaults = try freshDefaults("clear")
        CameraRestartMarker(defaults: defaults).record(version: "5")
        CameraRestartMarker(defaults: defaults).clear()
        XCTAssertNil(CameraRestartMarker(defaults: defaults).previousRequestedVersion)
    }

    func testNilVersionIsNeverTreatedAsTried() throws {
        let defaults = try freshDefaults("nil")
        CameraRestartMarker(defaults: defaults).record(version: "5")
        let next = CameraRestartMarker(defaults: defaults)
        XCTAssertFalse(next.wasRestartAlreadyTried(forBundled: nil))
    }

    func testRecordNilDoesNotPersist() throws {
        let defaults = try freshDefaults("record-nil")
        CameraRestartMarker(defaults: defaults).record(version: nil)
        XCTAssertNil(CameraRestartMarker(defaults: defaults).previousRequestedVersion)
    }

    /// An isolated, empty `UserDefaults` suite for a single test.
    private func freshDefaults(_ name: String) throws -> UserDefaults {
        let suite = "CameraRestartMarkerTests.\(name)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}

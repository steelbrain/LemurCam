@testable import LemurCam
import XCTest

/// The coordinator's reason to update a working microphone, which both the guided
/// setup's microphone step and the Settings status card show with an "Update
/// Microphone" action. After an app update the guided setup reopens on its own, and
/// its microphone step used to say only "Ready", hiding an older or unprotected
/// driver.
@MainActor
internal final class SetupCoordinatorUpdateReasonTests: XCTestCase {
    private var fixture: SetupCoordinatorFixture?

    override func setUp() async throws {
        try await super.setUp()
        fixture = try SetupCoordinatorFixture()
    }

    override func tearDown() async throws {
        fixture?.cleanUp()
        fixture = nil
        try await super.tearDown()
    }

    func testAnUnsealedCopyIsOfferedForUpdate() async throws {
        let harness = try XCTUnwrap(fixture)
        let ready = await harness.makeReady(version: "6", sealed: false)
        XCTAssertTrue(ready)
        XCTAssertEqual(harness.coordinator.microphoneUpdateReason, .unsealed)
        XCTAssertTrue(harness.coordinator.microphoneNeedsUpdate)
    }

    func testAnOlderCopyIsOfferedForUpdate() async throws {
        let harness = try XCTUnwrap(fixture)
        let ready = await harness.makeReady(version: "5")
        XCTAssertTrue(ready)
        XCTAssertEqual(harness.coordinator.microphoneUpdateReason, .newerVersion)
    }

    func testTheBundledSealedCopyNeedsNoUpdate() async throws {
        let harness = try XCTUnwrap(fixture)
        let ready = await harness.makeReady()
        XCTAssertTrue(ready)
        XCTAssertNil(harness.coordinator.microphoneUpdateReason)
        XCTAssertFalse(harness.coordinator.microphoneNeedsUpdate)
    }

    func testUpdateReinstallsThroughTheHelper() async throws {
        let harness = try XCTUnwrap(fixture)
        let ready = await harness.makeReady(version: "5")
        XCTAssertTrue(ready)
        harness.coordinator.updateMicrophone()
        XCTAssertEqual(harness.helper.installs.count, 1)
        XCTAssertEqual(harness.coordinator.micStatus, .installing)
    }

    func testEachReasonHasItsCopy() {
        XCTAssertEqual(MicrophoneStatusCopy.update(.unsealed), MicrophoneStatusCopy.unsealed)
        XCTAssertEqual(MicrophoneStatusCopy.update(.newerVersion), MicrophoneStatusCopy.newerVersion)
    }
}

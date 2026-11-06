@testable import LemurCam
import XCTest

/// Locks the "No camera available" placeholder when no camera is active. Launch,
/// and demand coming back after a pause, forced a resync by forgetting the active
/// source the coordinator had handled. With no active source there was nothing to
/// forget, so the resync saw nothing new and returned before starting the
/// placeholder, and an app opening the virtual camera got no frames at all.
@MainActor
internal final class StreamCoordinatorNoCameraPlaceholderTests: XCTestCase {
    private var fixture: CoordinatorHarness?

    override func setUp() async throws {
        try await super.setUp()
        fixture = nil
    }

    override func tearDown() async throws {
        fixture?.cleanUp()
        fixture = nil
        try await super.tearDown()
    }

    private func makeHarness(cameraInUse: Bool = false) -> CoordinatorHarness {
        let harness = CoordinatorHarness(cameraConsumerProbe: { cameraInUse })
        fixture = harness
        return harness
    }

    func testAnAppOpeningTheCameraGetsThePlaceholder() {
        let harness = makeHarness()
        harness.coordinator.start()
        XCTAssertNil(harness.manager.activeSourceID)
        XCTAssertNil(harness.coordinator.placeholderMessage, "nothing uses the camera yet")

        harness.coordinator.simulateCameraConsumerChange(active: true)

        XCTAssertEqual(harness.coordinator.placeholderMessage, "No camera available in LemurCam")
    }

    func testAnAppUsingTheCameraAtLaunchGetsThePlaceholder() {
        let harness = makeHarness(cameraInUse: true)

        harness.coordinator.start()

        XCTAssertEqual(harness.coordinator.placeholderMessage, "No camera available in LemurCam")
    }

    func testThePlaceholderComesBackWhenDemandReturns() {
        let harness = makeHarness()
        harness.coordinator.start()
        harness.coordinator.simulateCameraConsumerChange(active: true)
        harness.coordinator.simulateCameraConsumerChange(active: false)
        XCTAssertNil(harness.coordinator.placeholderMessage, "paused while nothing uses the camera")

        harness.coordinator.simulateCameraConsumerChange(active: true)

        XCTAssertEqual(harness.coordinator.placeholderMessage, "No camera available in LemurCam")
    }
}

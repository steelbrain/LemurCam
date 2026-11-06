@testable import LemurCam
import XCTest

/// Locks how `LemurCamModel` registers for the extension's camera consumer
/// notifications. Every model, test-built ones included, used to register for the
/// real, system-wide Darwin notifications. A LemurCam camera in use on the Mac then
/// started a test model's sink stream, with real CMIO calls on whatever objects had
/// the test's fake device and stream IDs. The registration is now injected; it must
/// last exactly as long as the model, since the real one removes its observers when
/// released.
internal final class LemurCamModelConsumerNotificationTests: XCTestCase {
    func testTheModelRegistersThroughTheInjectedObserverForItsLifetime() {
        let notifications = FakeConsumerNotifications()
        var model: LemurCamModel? = LemurCamModel(
            consumerProbe: { _ in false },
            consumerObserver: notifications.observe
        )

        XCTAssertTrue(notifications.isRegistered, "the model must register through the observer it was given")
        withExtendedLifetime(model) {
            XCTAssertTrue(notifications.isRegistered, "the registration must outlive init")
        }

        model = nil
        XCTAssertFalse(notifications.isRegistered, "releasing the model must end its registration")
    }
}

import CoreMedia
@testable import LemurCam
import XCTest

internal final class LemurCamStreamStateTests: XCTestCase {
    func testQueueAlteredRegistrationProvidesStableCallbackAndRefCon() {
        let registration = CMIOStreamQueueAlteredRegistration()
        let refConAddress = UInt(bitPattern: registration.refCon)

        XCTAssertNotEqual(refConAddress, 0)
        XCTAssertEqual(registration.refCon, registration.refCon)

        registration.callback(0, nil, registration.refCon)
    }

    func testStreamResourcesRetainQueueAlteredRegistrationUntilCleared() throws {
        let state = LemurCamStreamState()
        weak var weakRegistration: CMIOStreamQueueAlteredRegistration?

        do {
            let registration = CMIOStreamQueueAlteredRegistration()
            weakRegistration = registration
            let resources = CMIOStreamQueueResources(
                queue: SendableSimpleQueue(try makeQueue()),
                queueAlteredRegistration: registration
            )

            state.markStreamConnected(resources: resources)
        }

        XCTAssertTrue(state.hasStreamResources)
        XCTAssertNotNil(weakRegistration)

        state.clearStreamResources()

        XCTAssertFalse(state.hasStreamResources)
        XCTAssertNil(weakRegistration)
    }

    private func makeQueue() throws -> CMSimpleQueue {
        var queue: CMSimpleQueue?
        let status = CMSimpleQueueCreate(
            allocator: kCFAllocatorDefault,
            capacity: 1,
            queueOut: &queue
        )
        XCTAssertEqual(status, noErr)
        return try XCTUnwrap(queue)
    }
}

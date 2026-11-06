import CoreMedia
import CoreMediaIO
@testable import LemurCam
import XCTest

internal final class LemurCamStreamStateTests: XCTestCase {
    private let deviceID: CMIODeviceID = 10
    private let replacementID: CMIODeviceID = 20

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

    // MARK: - Buffers left in the sink queue

    /// A `CMSimpleQueue` never releases its elements, and `enqueue` hands it each
    /// buffer retained. When the device went away the queue was dropped with up to
    /// `Tuning.sinkBufferQueueSize` buffers still in it, leaking them every time.
    func testLosingTheDeviceReleasesTheBuffersLeftInTheSinkQueue() throws {
        let state = LemurCamStreamState()
        let queue = try makeQueue(capacity: Int32(Tuning.sinkBufferQueueSize))
        try connect(state, queue: queue)
        let freed = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        freed.initialize(to: 0)
        defer { freed.deallocate() }

        try autoreleasepool {
            let buffer = try makeSampleBuffer(countingFreesIn: freed)
            XCTAssertTrue(state.enqueue(buffer))
            XCTAssertTrue(state.enqueue(buffer))
        }
        XCTAssertEqual(freed.pointee, 0, "the queue holds the only retains left")

        XCTAssertEqual(state.deviceListChanged(.empty), .deviceLost)

        XCTAssertEqual(CMSimpleQueueGetCount(queue), 0, "the lost device's queue must be drained")
        XCTAssertEqual(freed.pointee, 1, "drained buffers must be released")
    }

    /// While the device is still listed CMIO may be dequeuing, so the queue and the
    /// buffers in it are left alone: they are CMIO's to consume.
    func testAListedDeviceKeepsItsQueuedBuffers() throws {
        let state = LemurCamStreamState()
        let queue = try makeQueue(capacity: Int32(Tuning.sinkBufferQueueSize))
        try connect(state, queue: queue)
        XCTAssertTrue(state.enqueue(try makeSampleBuffer()))

        XCTAssertEqual(state.deviceListChanged(.lemur(deviceID)), .unchanged)
        XCTAssertEqual(CMSimpleQueueGetCount(queue), 1)

        XCTAssertEqual(SendableSimpleQueue(queue).releaseRetainedElements(), 1)
    }

    /// A device replaced by another in one device-list change used to have its
    /// queue dropped without the drain a lost device gets. Once the old device is
    /// no longer listed, CMIO no longer dequeues from it, so it is drained too.
    func testReplacingTheDeviceReleasesTheBuffersLeftInTheSinkQueue() throws {
        let state = LemurCamStreamState()
        let queue = try makeQueue(capacity: Int32(Tuning.sinkBufferQueueSize))
        try connect(state, queue: queue)
        let freed = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        freed.initialize(to: 0)
        defer { freed.deallocate() }

        try autoreleasepool {
            let buffer = try makeSampleBuffer(countingFreesIn: freed)
            XCTAssertTrue(state.enqueue(buffer))
            XCTAssertTrue(state.enqueue(buffer))
        }
        XCTAssertEqual(freed.pointee, 0, "the queue holds the only retains left")

        XCTAssertEqual(state.deviceListChanged(.lemur(replacementID)), .deviceReplaced)

        XCTAssertEqual(CMSimpleQueueGetCount(queue), 0, "the replaced device's queue must be drained")
        XCTAssertEqual(freed.pointee, 1, "drained buffers must be released")
    }

    /// The old device is still listed beside its replacement, so CMIO may still be
    /// dequeuing: its buffers are left alone until a readable list no longer shows
    /// it. They used to be dropped with the queue and leak.
    func testAReplacedDeviceThatIsStillListedKeepsItsQueuedBuffersUntilUnlisted() throws {
        let state = LemurCamStreamState()
        let queue = try makeQueue(capacity: Int32(Tuning.sinkBufferQueueSize))
        try connect(state, queue: queue)
        let freed = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        freed.initialize(to: 0)
        defer { freed.deallocate() }
        try autoreleasepool {
            XCTAssertTrue(state.enqueue(try makeSampleBuffer(countingFreesIn: freed)))
        }

        let list = CMIODeviceList.read(deviceIDs: [deviceID, replacementID], lemurDeviceID: replacementID)
        XCTAssertEqual(state.deviceListChanged(list), .deviceReplaced)
        XCTAssertEqual(rediscover(state, as: replacementID), .ready(deviceID: replacementID))
        XCTAssertEqual(state.deviceListChanged(.unreadable), .recheck)
        XCTAssertEqual(CMSimpleQueueGetCount(queue), 1)

        XCTAssertEqual(state.deviceListChanged(.lemur(replacementID)), .unchanged)
        XCTAssertEqual(CMSimpleQueueGetCount(queue), 0, "the old device is no longer listed")
        XCTAssertEqual(freed.pointee, 1)
    }

    /// A discovery pass runs on the same serial queue as the device-list listener,
    /// so it can see the replacement device before the listener's change is applied.
    /// Discovery dropped the old queue with its buffers in it, and the change, which
    /// then found the new device cached, had nothing to drain: up to a queue's worth
    /// of frames leaked with every replacement.
    func testADeviceReplacedByDiscoveryReleasesItsBuffersOnceUnlisted() throws {
        let state = LemurCamStreamState()
        let queue = try makeQueue(capacity: Int32(Tuning.sinkBufferQueueSize))
        try connect(state, queue: queue)
        let freed = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        freed.initialize(to: 0)
        defer { freed.deallocate() }
        try autoreleasepool {
            let buffer = try makeSampleBuffer(countingFreesIn: freed)
            XCTAssertTrue(state.enqueue(buffer))
            XCTAssertTrue(state.enqueue(buffer))
        }

        XCTAssertEqual(rediscover(state, as: replacementID), .ready(deviceID: replacementID))
        XCTAssertEqual(CMSimpleQueueGetCount(queue), 2, "the old device may still be listed")
        XCTAssertEqual(freed.pointee, 0)

        XCTAssertEqual(state.deviceListChanged(.lemur(replacementID)), .unchanged)
        XCTAssertEqual(CMSimpleQueueGetCount(queue), 0, "the old device's queue must be drained")
        XCTAssertEqual(freed.pointee, 1, "drained buffers must be released")
    }

    /// While a list may still show the device discovery replaced, its queue is left
    /// to CMIO; draining it later leaves the new device's live queue alone.
    func testADeviceReplacedByDiscoveryKeepsItsBuffersWhileItMayBeListed() throws {
        let state = LemurCamStreamState()
        let oldQueue = try makeQueue(capacity: Int32(Tuning.sinkBufferQueueSize))
        try connect(state, queue: oldQueue)
        XCTAssertTrue(state.enqueue(try makeSampleBuffer()))
        XCTAssertEqual(rediscover(state, as: replacementID), .ready(deviceID: replacementID))
        let newQueue = try makeQueue(capacity: Int32(Tuning.sinkBufferQueueSize))
        try startSinkStream(state, queue: newQueue)
        XCTAssertTrue(state.enqueue(try makeSampleBuffer()))

        let bothListed = CMIODeviceList.read(deviceIDs: [deviceID, replacementID], lemurDeviceID: replacementID)
        XCTAssertEqual(state.deviceListChanged(bothListed), .unchanged)
        XCTAssertEqual(state.deviceListChanged(.unreadable), .recheck)
        XCTAssertEqual(CMSimpleQueueGetCount(oldQueue), 1)

        let oldUnlisted = CMIODeviceList.read(deviceIDs: [replacementID, 30], lemurDeviceID: replacementID)
        XCTAssertEqual(state.deviceListChanged(oldUnlisted), .unchanged)
        XCTAssertEqual(CMSimpleQueueGetCount(oldQueue), 0)
        XCTAssertEqual(CMSimpleQueueGetCount(newQueue), 1, "the live queue is CMIO's to consume")

        XCTAssertEqual(SendableSimpleQueue(newQueue).releaseRetainedElements(), 1)
    }

    /// A device list that can't be read says nothing about whether the device is
    /// gone, so the device keeps its queue and the buffers in it.
    func testAnUnreadableDeviceListKeepsTheQueuedBuffers() throws {
        let state = LemurCamStreamState()
        let queue = try makeQueue(capacity: Int32(Tuning.sinkBufferQueueSize))
        try connect(state, queue: queue)
        XCTAssertTrue(state.enqueue(try makeSampleBuffer()))

        XCTAssertEqual(state.deviceListChanged(.unreadable), .recheck)
        XCTAssertEqual(CMSimpleQueueGetCount(queue), 1)
        XCTAssertTrue(state.hasStreamResources)

        XCTAssertEqual(SendableSimpleQueue(queue).releaseRetainedElements(), 1)
    }
}

// MARK: - Helpers

private extension LemurCamStreamStateTests {
    func connect(_ state: LemurCamStreamState, queue: CMSimpleQueue) throws {
        XCTAssertEqual(rediscover(state, as: deviceID), .ready(deviceID: deviceID))
        try startSinkStream(state, queue: queue)
    }

    /// Run a discovery pass that finds the device `newDeviceID`.
    func rediscover(
        _ state: LemurCamStreamState, as newDeviceID: CMIODeviceID
    ) -> LemurCamStreamState.DiscoveryResultAction {
        state.requestDiscovery()
        XCTAssertEqual(state.prepareRetry(maxRetries: 1), .discover(attempt: 1))
        return state.applyDiscoveryResult((deviceID: newDeviceID, streamID: newDeviceID + 1))
    }

    func startSinkStream(_ state: LemurCamStreamState, queue: CMSimpleQueue) throws {
        _ = try XCTUnwrap(state.beginStarting())
        state.markStreamConnected(
            resources: CMIOStreamQueueResources(
                queue: SendableSimpleQueue(queue),
                queueAlteredRegistration: CMIOStreamQueueAlteredRegistration()
            )
        )
    }

    func makeSampleBuffer() throws -> CMSampleBuffer {
        var buffer: CMSampleBuffer?
        let status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: nil,
            sampleCount: 0, sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &buffer
        )
        XCTAssertEqual(status, noErr)
        return try XCTUnwrap(buffer)
    }

    /// A one-sample buffer whose data block, owned only by the buffer, adds one to
    /// `counter` when it is freed: when the last retain on the buffer goes away.
    func makeSampleBuffer(countingFreesIn counter: UnsafeMutablePointer<Int>) throws -> CMSampleBuffer {
        let length = 16
        var source = CMBlockBufferCustomBlockSource(
            version: kCMBlockBufferCustomBlockSourceVersion,
            AllocateBlock: nil,
            FreeBlock: { refCon, block, _ in
                refCon?.assumingMemoryBound(to: Int.self).pointee += 1
                block.deallocate()
            },
            refCon: UnsafeMutableRawPointer(counter)
        )
        var block: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: UnsafeMutableRawPointer.allocate(byteCount: length, alignment: 16),
            blockLength: length, blockAllocator: nil, customBlockSource: &source,
            offsetToData: 0, dataLength: length, flags: 0, blockBufferOut: &block
        ), noErr)
        var sampleSize = length
        var buffer: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: try XCTUnwrap(block), dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: nil,
            sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &buffer
        ), noErr)
        return try XCTUnwrap(buffer)
    }

    func makeQueue(capacity: Int32 = 1) throws -> CMSimpleQueue {
        var queue: CMSimpleQueue?
        let status = CMSimpleQueueCreate(
            allocator: kCFAllocatorDefault,
            capacity: capacity,
            queueOut: &queue
        )
        XCTAssertEqual(status, noErr)
        return try XCTUnwrap(queue)
    }
}

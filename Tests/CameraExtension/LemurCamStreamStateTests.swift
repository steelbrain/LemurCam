import CoreMedia
import CoreMediaIO
@testable import LemurCam
import XCTest

internal final class LemurCamStreamStateTests: XCTestCase {
    private let deviceID: CMIODeviceID = 10

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

        XCTAssertEqual(state.deviceListChanged(lemurDeviceID: nil), .deviceLost)

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

        XCTAssertEqual(state.deviceListChanged(lemurDeviceID: deviceID), .unchanged)
        XCTAssertEqual(CMSimpleQueueGetCount(queue), 1)

        XCTAssertEqual(SendableSimpleQueue(queue).releaseRetainedElements(), 1)
    }

    // MARK: - Helpers

    private func connect(_ state: LemurCamStreamState, queue: CMSimpleQueue) throws {
        state.requestDiscovery()
        XCTAssertEqual(state.prepareRetry(maxRetries: 1), .discover(attempt: 1))
        XCTAssertEqual(state.applyDiscoveryResult((deviceID: deviceID, streamID: 11)), .ready(deviceID: deviceID))
        _ = try XCTUnwrap(state.beginStarting())
        state.markStreamConnected(
            resources: CMIOStreamQueueResources(
                queue: SendableSimpleQueue(queue),
                queueAlteredRegistration: CMIOStreamQueueAlteredRegistration()
            )
        )
    }

    private func makeSampleBuffer() throws -> CMSampleBuffer {
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
    private func makeSampleBuffer(countingFreesIn counter: UnsafeMutablePointer<Int>) throws -> CMSampleBuffer {
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

    private func makeQueue(capacity: Int32 = 1) throws -> CMSimpleQueue {
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

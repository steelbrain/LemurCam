import CoreMedia

internal final class SendableSimpleQueue: Sendable {
    private let queue: SendableRetainedReference<CMSimpleQueue>

    init(_ value: CMSimpleQueue) {
        self.queue = SendableRetainedReference(value)
    }

    func withValue<Result>(_ body: (CMSimpleQueue) throws -> Result) rethrows -> Result {
        try queue.withValue(body)
    }

    func enqueueRetainedElement(at elementAddress: UInt) -> Bool {
        withValue { queue in
            guard CMSimpleQueueGetCount(queue) < CMSimpleQueueGetCapacity(queue),
                  let rawElement = UnsafeMutableRawPointer(bitPattern: elementAddress) else {
                return false
            }
            return CMSimpleQueueEnqueue(queue, element: rawElement) == noErr
        }
    }

    /// Dequeue every element still in the queue and release the retain it was
    /// enqueued with: a `CMSimpleQueue` holds bare pointers and never releases them.
    /// The queue supports only one dequeuing thread, so call this only once nothing
    /// else (CMIO) can dequeue from it. Returns how many elements were released.
    @discardableResult
    func releaseRetainedElements() -> Int {
        withValue { queue in
            var released = 0
            while let element = CMSimpleQueueDequeue(queue) {
                Unmanaged<AnyObject>.fromOpaque(element).release()
                released += 1
            }
            return released
        }
    }
}

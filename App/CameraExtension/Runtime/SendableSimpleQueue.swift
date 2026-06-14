import CoreMedia
import Foundation

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
}

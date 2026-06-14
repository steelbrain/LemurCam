import Foundation

/// Retains an Objective-C/CoreFoundation-style reference while it crosses a
/// Swift concurrency or dispatch boundary that does not model the type as
/// `Sendable`.
internal final class SendableRetainedReference<Value: AnyObject>: Sendable {
    private let address: UInt

    init(_ value: Value) {
        self.address = UInt(bitPattern: Unmanaged.passRetained(value).toOpaque())
    }

    deinit {
        Unmanaged<Value>.fromOpaque(rawPointer).release()
    }

    func withValue<Result>(_ body: (Value) throws -> Result) rethrows -> Result {
        let value = Unmanaged<Value>.fromOpaque(rawPointer).takeUnretainedValue()
        return try body(value)
    }

    private var rawPointer: UnsafeRawPointer {
        guard let retainedPointer = UnsafeRawPointer(bitPattern: address) else {
            preconditionFailure("Invalid retained reference pointer")
        }
        return retainedPointer
    }
}

/// Stores a non-owning object address for callbacks that must avoid capturing
/// non-Sendable references directly. The caller must guarantee the value lives
/// at least as long as any use of this wrapper.
internal struct SendableUnretainedReference<Value: AnyObject>: Sendable {
    private let address: UInt

    init(_ value: Value) {
        self.address = UInt(bitPattern: Unmanaged.passUnretained(value).toOpaque())
    }

    func withValue<Result>(_ body: (Value) throws -> Result) rethrows -> Result {
        let value = Unmanaged<Value>.fromOpaque(rawPointer).takeUnretainedValue()
        return try body(value)
    }

    private var rawPointer: UnsafeRawPointer {
        guard let unretainedPointer = UnsafeRawPointer(bitPattern: address) else {
            preconditionFailure("Invalid unretained reference pointer")
        }
        return unretainedPointer
    }
}

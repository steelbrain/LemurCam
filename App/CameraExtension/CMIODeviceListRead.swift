import CoreMediaIO

/// Reading the CMIO device list takes two calls, one for its size and one for its
/// data, and devices can come and go between them. A device added in between leaves
/// the list larger than the buffer, which CMIO may fill only as far as it goes, so a
/// device that was there could be missing from what was read: a cached LemurCam
/// device then looked gone, and the sink queue of a replaced one was drained while
/// CMIO might still be dequeuing from it. One removed in between left the end of the
/// buffer unfilled, and its zeros were read as device IDs. Makes no CMIO calls of its
/// own, so the decision is unit-testable.
internal enum CMIODeviceListRead {
    /// How many times the list is read before it counts as unreadable
    /// (`CMIODeviceList.unreadable`, which keeps everything).
    static let maxAttempts = 3

    /// What one attempt at reading the list saw.
    struct Attempt {
        /// The list's size in bytes, asked for before the read.
        let sizeBefore: UInt32
        /// The buffer the read filled, sized from `sizeBefore`.
        let buffer: [CMIODeviceID]
        /// The bytes the read filled.
        let dataUsed: UInt32
        /// The list's size in bytes, asked for again after the read.
        let sizeAfter: UInt32

        /// Whether the read holds the whole list. Not when it filled less than the size
        /// asked for before it (the list shrank, or CMIO stopped short), nor when the
        /// size asked for after it differs (the list grew or shrank meanwhile), nor
        /// when what it filled isn't a whole number of IDs within the buffer.
        var holdsWholeList: Bool {
            let used = Int(dataUsed)
            return dataUsed == sizeBefore && sizeAfter == sizeBefore
                && used.isMultiple(of: Self.idSize) && used / Self.idSize <= buffer.count
        }

        /// The IDs in the bytes the read filled.
        var deviceIDs: [CMIODeviceID] {
            Array(buffer.prefix(Int(dataUsed) / Self.idSize))
        }

        private static let idSize = MemoryLayout<CMIODeviceID>.stride
    }

    /// Every read of the list missed part of it, or may have.
    struct KeptChanging: Error {
        let attempts: Int
    }

    /// Reads the list with `attempt` until one read holds the whole list, at most
    /// `maxAttempts` times, and throws `KeptChanging` when none did. A read that
    /// fails is thrown at once.
    static func read(maxAttempts: Int = maxAttempts, attempt: () throws -> Attempt) throws -> [CMIODeviceID] {
        for _ in 0..<maxAttempts {
            let read = try attempt()
            if read.holdsWholeList { return read.deviceIDs }
        }
        throw KeptChanging(attempts: maxAttempts)
    }
}

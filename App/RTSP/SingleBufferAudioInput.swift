import AVFoundation
import os

internal final class SingleBufferAudioInput: Sendable {
    private let buffer: SendableRetainedReference<AVAudioPCMBuffer>
    private let wasSupplied = OSAllocatedUnfairLock<Bool>(initialState: false)

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = SendableRetainedReference(buffer)
    }

    func next(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        let shouldSupply = wasSupplied.withLock { supplied in
            guard !supplied else { return false }
            supplied = true
            return true
        }

        guard shouldSupply else {
            status.pointee = .noDataNow
            return nil
        }

        status.pointee = .haveData
        return buffer.withValue { $0 }
    }
}

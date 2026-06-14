import Foundation
import os

internal struct DualLogger {
    private static let emitSink = DualLoggerSink()

    static var onEmit: (@Sendable (String, String, String) -> Void)? {
        get { emitSink.value }
        set { emitSink.value = newValue }
    }

    private let logger: Logger
    private let category: String

    init(subsystem: String, category: String) {
        self.logger = Logger(subsystem: subsystem, category: category)
        self.category = category
    }

    func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
        emit("DEBUG", message)
    }

    func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        emit("INFO", message)
    }

    func warning(_ message: String) {
        logger.warning("\(message, privacy: .public)")
        emit("WARN", message)
    }

    func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        emit("ERROR", message)
    }

    func fault(_ message: String) {
        logger.fault("\(message, privacy: .public)")
        emit("FAULT", message)
    }

    private func emit(_ level: String, _ message: String) {
        let line = "[\(category)] \(level): \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
        Self.onEmit?(category, level, message)
    }
}

private final class DualLoggerSink: Sendable {
    private typealias Callback = @Sendable (String, String, String) -> Void

    private let callback = OSAllocatedUnfairLock<Callback?>(initialState: nil)

    var value: (@Sendable (String, String, String) -> Void)? {
        get {
            callback.withLock { $0 }
        }
        set {
            callback.withLock { $0 = newValue }
        }
    }
}

import Foundation

internal struct LogEntry: Identifiable {
    let id = UUID()
    let date: Date
    let category: String
    let level: String
    let message: String
}

@MainActor @Observable
internal final class LogStore {
    static let shared = LogStore()

    private(set) var entries: [LogEntry] = []

    private static let maxEntries = 1000

    private init() {
        entries.reserveCapacity(Self.maxEntries)
    }

    func append(category: String, level: String, message: String) {
        let entry = LogEntry(date: Date(), category: category, level: level, message: message)
        entries.append(entry)
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
        }
    }

    func clear() {
        entries.removeAll()
    }
}

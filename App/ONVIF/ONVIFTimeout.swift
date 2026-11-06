import Foundation

/// Time limits for ONVIF traffic. `URLSessionConfiguration.timeoutIntervalForRequest`
/// only limits the gap between packets, and the resource timeout defaults to seven
/// days, so a device that trickles bytes could hold a request open indefinitely.
internal enum ONVIFTimeout {
    /// Longest one HTTP exchange may take, including the response body.
    static let resource: TimeInterval = 15

    /// Longest a fetch started from the add/edit camera forms may take. It covers the
    /// clock and capabilities requests that precede the operation itself.
    static let interactiveFetch: TimeInterval = 30

    /// Longest the launch-time reachability probe of one camera may take.
    static let launchProbe: TimeInterval = 20

    /// Runs `operation`, throwing `ONVIFError.timedOut` and cancelling it if it has
    /// not finished after `seconds`.
    static func run<T: Sendable>(
        seconds: TimeInterval,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw ONVIFError.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw ONVIFError.timedOut }
            return result
        }
    }
}

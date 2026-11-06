import Foundation

/// Runs a tool with a deadline. The helper runs every privileged operation on one
/// serial queue, so a `launchctl` that never exits would otherwise hold up every
/// later install, removal, and version query until the helper is restarted.
/// Compiled into the app only for the unit tests.
internal enum BoundedProcess {
    /// Runs `tool` with `arguments`, discarding its output, and returns its exit
    /// status. If it has not exited after `timeout` seconds it is sent SIGTERM, then
    /// SIGKILL after `killGrace` more, and the status it ended with is returned
    /// (the signal number). Returns -1 if it could not be launched or did not end.
    static func run(_ tool: String, _ arguments: [String], timeout: TimeInterval,
                    killGrace: TimeInterval = 2) -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: tool)
        task.arguments = arguments
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in exited.signal() }
        do {
            try task.run()
        } catch {
            return -1
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            // `isRunning` first: signalling a process that has already been reaped
            // could reach another one that reused its PID.
            if task.isRunning { task.terminate() }
            if exited.wait(timeout: .now() + killGrace) == .timedOut {
                if task.isRunning { kill(task.processIdentifier, SIGKILL) }
                guard exited.wait(timeout: .now() + killGrace) == .success else { return -1 }
            }
        }
        return task.terminationStatus
    }
}

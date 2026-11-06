import Foundation
import os

/// Entry point for the privileged helper daemon. launchd starts this on demand
/// when the app first connects to the registered Mach service; the listener then
/// vends `HelperService` instances to authenticated app connections. Once idle the
/// helper exits (`HelperIdleExit`), so the next request starts the current binary.
///
/// Named `HelperMain.swift` (not `main.swift`) so `@main` provides the entry
/// point without top-level executable statements.
@main
internal enum HelperMain {
    static func main() {
        let log = Logger(subsystem: LemurAudioHelper.machServiceName, category: "lifecycle")
        let idle = HelperIdleExit(
            grace: HelperIdleExit.defaultGrace,
            schedule: { delay, action in DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: action) },
            exit: {
                log.info("idle, exiting until the next request")
                Darwin.exit(0)
            }
        )
        let delegate = HelperListenerDelegate(idle: idle)
        let listener = NSXPCListener(machServiceName: LemurAudioHelper.machServiceName)
        listener.delegate = delegate
        listener.resume()
        idle.start()
        // Never returns; keeps `delegate` and `listener` alive until the idle exit.
        dispatchMain()
    }
}

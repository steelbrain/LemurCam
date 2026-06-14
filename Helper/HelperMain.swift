import Foundation

/// Entry point for the privileged helper daemon. launchd starts this on demand
/// when the app first connects to the registered Mach service; the listener then
/// vends `HelperService` instances to authenticated app connections.
///
/// Named `HelperMain.swift` (not `main.swift`) so `@main` provides the entry
/// point without top-level executable statements.
@main
internal enum HelperMain {
    static func main() {
        let delegate = HelperListenerDelegate()
        let listener = NSXPCListener(machServiceName: LemurAudioHelper.machServiceName)
        listener.delegate = delegate
        listener.resume()
        // Never returns; keeps `delegate` and `listener` alive for the daemon's life.
        dispatchMain()
    }
}

import Foundation
import os

/// Accepts incoming XPC connections only from the LemurCam app (pinned by code-
/// signing requirement) and wires each one to a fresh `HelperService`. Each open
/// connection keeps the helper from exiting while idle.
internal final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let log = Logger(subsystem: LemurAudioHelper.machServiceName, category: "listener")
    private let idle: HelperIdleExit

    init(idle: HelperIdleExit) {
        self.idle = idle
    }

    func listener(_: NSXPCListener,
                  shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // The requirement set below is enforced per message, so a process that
        // opens a connection and never sends anything would pass it, and could
        // keep the helper (and whatever version it runs) up for good. Check the
        // peer before counting its connection.
        if case .failure(let failure) = CallerCode.appBundlePath(of: newConnection) {
            log.error("refused connection: \(failure.description, privacy: .public)")
            return false
        }
        // Already exiting: refuse, so the client fails now and its retry reaches
        // the next launch instead of a process about to end.
        guard let activity = idle.begin() else { return false }
        // Reject any peer that is not our app, signed by our team. Must be set
        // before the connection is resumed.
        newConnection.setCodeSigningRequirement(LemurAudioHelper.appRequirement)
        newConnection.exportedInterface = NSXPCInterface(with: LemurAudioHelperProtocol.self)
        newConnection.exportedObject = HelperService(idle: idle)
        newConnection.invalidationHandler = { activity.end() }
        newConnection.resume()
        log.info("accepted new XPC connection")
        return true
    }
}

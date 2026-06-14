import Foundation
import OSLog

/// Accepts incoming XPC connections only from the LemurCam app (pinned by code-
/// signing requirement) and wires each one to a fresh `HelperService`.
internal final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let log = Logger(subsystem: LemurAudioHelper.machServiceName, category: "listener")

    func listener(_: NSXPCListener,
                  shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // Reject any peer that is not our app, signed by our team. Must be set
        // before the connection is resumed.
        newConnection.setCodeSigningRequirement(LemurAudioHelper.appRequirement)
        newConnection.exportedInterface = NSXPCInterface(with: LemurAudioHelperProtocol.self)
        newConnection.exportedObject = HelperService()
        newConnection.resume()
        log.info("accepted new XPC connection")
        return true
    }
}

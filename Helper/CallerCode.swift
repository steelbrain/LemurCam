import Foundation
import Security

/// Locates the app bundle of the process on the other end of an XPC connection, so
/// the helper installs the driver that ships inside the calling app instead of any
/// path the caller names.
internal enum CallerCode {
    typealias Failure = DriverBundleFiles.Failure

    /// Bundle path of the calling app, after re-checking that the code it was derived
    /// from satisfies `LemurAudioHelper.appRequirement`.
    static func appBundlePath(of connection: NSXPCConnection) -> Result<String, Failure> {
        var attributes: [CFString: Any] = [:]
        if let token = auditToken(of: connection) {
            attributes[kSecGuestAttributeAudit] = token
        } else {
            // PIDs can be reused, but the requirement check below still only accepts
            // another LemurCam app process, whose own bundle is then used.
            attributes[kSecGuestAttributePid] = NSNumber(value: connection.processIdentifier)
        }
        var guest: SecCode?
        let guestStatus = SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, [], &guest)
        guard guestStatus == errSecSuccess, let code = guest else {
            return .failure(Failure(description: "Could not identify the calling app (\(guestStatus))"))
        }
        var requirement: SecRequirement?
        let requirementStatus = SecRequirementCreateWithString(
            LemurAudioHelper.appRequirement as CFString, [], &requirement
        )
        guard requirementStatus == errSecSuccess, let requirement else {
            return .failure(Failure(description: "SecRequirementCreateWithString failed (\(requirementStatus))"))
        }
        // The connection enforces the same requirement per message; checking the code
        // object the path comes from ties the path to that validated caller.
        let validity = SecCodeCheckValidity(code, [], requirement)
        guard validity == errSecSuccess else {
            return .failure(Failure(description: "The calling app failed its code-signing check (\(validity))"))
        }
        var staticCode: SecStaticCode?
        var url: CFURL?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopyPath(staticCode, [], &url) == errSecSuccess, let url else {
            return .failure(Failure(description: "Could not locate the calling app on disk"))
        }
        return .success((url as URL).path)
    }

    /// The peer's audit token. NSXPCConnection exposes it only through its
    /// long-standing but undocumented `auditToken` property; `responds(to:)` guards
    /// the KVC read so a system without it falls back to the PID instead of raising.
    private static func auditToken(of connection: NSXPCConnection) -> Data? {
        guard connection.responds(to: NSSelectorFromString("auditToken")),
              let value = connection.value(forKey: "auditToken") as? NSValue else { return nil }
        var token = audit_token_t()
        value.getValue(&token, size: MemoryLayout<audit_token_t>.size)
        return withUnsafeBytes(of: &token) { Data($0) }
    }
}

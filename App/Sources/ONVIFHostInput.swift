import Foundation

/// Checks the host typed into the edit form of an ONVIF camera, and the host of an
/// ONVIF URL typed into the add form (`ONVIFURLInput`). The host goes into the device
/// service URL as typed, only an IPv6 address put in brackets (`ONVIFClient.urlHost`),
/// so `admin:secret@192.168.1.64` made a valid
/// `http://admin:secret@192.168.1.64:80/onvif/device_service`: Fetch Profiles worked,
/// and the login was saved in the cameras file and shown in the camera list.
internal enum ONVIFHostInput {
    static let loginMessage =
        "Enter only the camera's address here. Enter its user name and password under Requires Authentication."

    static let notAnAddressMessage =
        "Enter only the camera's address here (e.g. 192.168.1.64), without http://, a path or spaces."

    static let portMessage = "Enter the port in the Port field below, not after the address."

    /// Nil when `host` has none of what can't be in a host name or an IP address and
    /// would change what the device service URL means: an `@` (a login before it), a
    /// `/`, `?` or `#` (the host ends there), whitespace or a control character. Nor
    /// can it end in a port (`hasPort`): the URL got a second one, which no URL can
    /// hold, so Fetch Profiles always failed.
    static func problem(with host: String) -> String? {
        let scalars = host.unicodeScalars
        if scalars.contains("@") { return loginMessage }
        let notInAHost = scalars.contains { scalar in
            "/?#".unicodeScalars.contains(scalar) || scalar.properties.isWhitespace
                || scalar.value < 0x20 || scalar.value == 0x7F
        }
        if notInAHost { return notAnAddressMessage }
        return hasPort(host) ? portMessage : nil
    }

    /// Whether `host` ends in a port, or the start of one: a host name or an IPv4
    /// address followed by a `:` and digits (`192.168.1.64:8080`), or a bracketed IPv6
    /// address followed by them (`[fe80::1]:8080`). An unbracketed IPv6 address has more
    /// than one `:`, and is read as an address.
    static func hasPort(_ host: String) -> Bool {
        let scalars = host.unicodeScalars
        let port: Substring.UnicodeScalarView
        if scalars.first == "[", let close = scalars.firstIndex(of: "]") {
            port = scalars[scalars.index(after: close)...]
        } else if let colon = scalars.firstIndex(of: ":"), scalars.lastIndex(of: ":") == colon {
            port = scalars[colon...]
        } else {
            return false
        }
        return port.first == ":" && port.dropFirst().allSatisfy { ("0"..."9").contains($0) }
    }
}

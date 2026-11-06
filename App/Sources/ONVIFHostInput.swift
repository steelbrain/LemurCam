import Foundation

/// Checks the host typed into the edit form of an ONVIF camera. The host goes into the
/// device service URL as typed (`ONVIFClient`), so `admin:secret@192.168.1.64` made a
/// valid `http://admin:secret@192.168.1.64:80/onvif/device_service`: Fetch Profiles
/// worked, and the login was saved in the cameras file and shown in the camera list.
internal enum ONVIFHostInput {
    static let loginMessage =
        "Enter only the camera's address here. Enter its user name and password under Requires Authentication."

    static let notAnAddressMessage =
        "Enter only the camera's address here (e.g. 192.168.1.64), without http://, a path or spaces."

    /// Nil when `host` has none of what can't be in a host name or an IP address and
    /// would change what the device service URL means: an `@` (a login before it), a
    /// `/`, `?` or `#` (the host ends there), whitespace or a control character.
    static func problem(with host: String) -> String? {
        let scalars = host.unicodeScalars
        if scalars.contains("@") { return loginMessage }
        let notInAHost = scalars.contains { scalar in
            "/?#".unicodeScalars.contains(scalar) || scalar.properties.isWhitespace
                || scalar.value < 0x20 || scalar.value == 0x7F
        }
        return notInAHost ? notAnAddressMessage : nil
    }
}

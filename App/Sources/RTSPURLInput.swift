import Foundation

/// Checks the RTSP URL typed into the add/edit camera form.
internal enum RTSPURLInput {
    static let invalidMessage = "Enter a valid RTSP URL (e.g. rtsp://192.168.1.100:554/stream)"

    /// Shown for a URL `SourceCredentials.hasAmbiguousUserInfo` flags, which IPCamKit
    /// would refuse to connect to.
    static let ambiguousUserInfoMessage =
        "The user name or password in this URL contains /, ?, # or @, so the camera's address can't be "
        + "read from it. Enter them under Requires Authentication instead, or write those characters as "
        + "%2F, %3F, %23 and %40. An @ in the path must also be written as %40."

    /// The field's text as the form uses it, without surrounding whitespace. A leading
    /// space made the URL unparseable, and a trailing one was saved and then rejected
    /// when connecting.
    static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Nil when `url` (already normalized) is an RTSP URL the app can use; otherwise
    /// what to tell the user.
    static func problem(with url: String) -> String? {
        if SourceCredentials.hasAmbiguousUserInfo(url) { return ambiguousUserInfoMessage }
        guard let components = URLComponents(string: url),
              let scheme = components.scheme?.lowercased(), scheme == "rtsp" || scheme == "rtsps",
              let host = components.host, !host.isEmpty else { return invalidMessage }
        return nil
    }
}

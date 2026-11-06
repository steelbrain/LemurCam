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

    /// Shown for a URL with a space, which IPCamKit refuses to connect to.
    static let spaceMessage =
        "A URL can't contain spaces. Write each space as %20, or enter a user name or password that has "
        + "one under Requires Authentication instead."

    /// Shown for a URL with a tab, a line break or another control character, which
    /// IPCamKit refuses to connect to.
    static let controlCharacterMessage =
        "This URL contains a tab, a line break or another invisible control character. Remove it."

    /// The field's text as the form uses it, without surrounding whitespace. A leading
    /// space made the URL unparseable, and a trailing one was saved and then rejected
    /// when connecting.
    static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Nil when `url` (already normalized) is an RTSP URL the app can use; otherwise
    /// what to tell the user.
    static func problem(with url: String) -> String? {
        if let problem = characterProblem(in: url) { return problem }
        if SourceCredentials.hasAmbiguousUserInfo(url) { return ambiguousUserInfoMessage }
        guard let components = URLComponents(cameraURL: url),
              let scheme = components.scheme?.lowercased(), scheme == "rtsp" || scheme == "rtsps",
              let host = components.host, !host.isEmpty else { return invalidMessage }
        return nil
    }

    /// What to tell the user about a space or a control character (U+0000 to U+001F,
    /// U+007F) in `url`, which IPCamKit refuses to connect to (its
    /// `checkURLCharacters`): it would end the RTSP request line early. `URLComponents`
    /// percent-encodes them, so such a URL passed the other checks and was refused on
    /// every connect. Written as `%20`, a space is accepted, and so are non-ASCII
    /// characters, which IPCamKit percent-encodes itself.
    static func characterProblem(in url: String) -> String? {
        if url.unicodeScalars.contains(" ") { return spaceMessage }
        if url.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            return controlCharacterMessage
        }
        return nil
    }
}

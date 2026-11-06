import Foundation

internal struct SourceCredentials: Equatable {
    var username: String
    var password: String
}

internal extension SourceCredentials {
    /// Split any `user:password@` userinfo out of an RTSP(S) URL so credentials are
    /// never persisted inside the stored URL string — they belong in the Keychain.
    /// Returns the URL with userinfo removed and the extracted credentials. Userinfo is
    /// removed whenever present, including a password with an empty user name
    /// (`rtsp://:secret@host`); credentials are nil when both parts are empty.
    ///
    /// `URLComponents` misreads userinfo holding a raw `/`, `?`, `#` or `@`: it fails
    /// on `rtsp://admin:Admin#123@cam/s` and reads `rtsp://admin:1234/5@cam/s` as host
    /// `admin`, port 1234. Such a URL is split at its last `@` instead (see
    /// `ambiguousUserInfo`). Any other URL that can't be parsed is returned unchanged.
    static func extractingFromRTSPURL(
        _ urlString: String
    ) -> (url: String, credentials: SourceCredentials?) {
        let (cleaned, login) = extractingLoginFromRTSPURL(urlString)
        return (cleaned, login?.credentials)
    }

    /// `extractingFromRTSPURL`, telling which parts of the login the URL holds: a user
    /// name only when it is not empty, a password whenever the userinfo has one, even
    /// an empty one (`admin:@cam`, but not `admin@cam`). Nil when both parts are empty.
    static func extractingLoginFromRTSPURL(_ urlString: String) -> (url: String, login: URLLogin?) {
        if let split = AmbiguousUserInfo(urlString) {
            return (split.urlWithout, split.login)
        }
        return extractingReadableLogin(from: urlString)
    }

    /// `urlString` without any userinfo, for display and for URLs whose embedded
    /// credentials are not wanted.
    static func strippingUserInfo(from urlString: String) -> String {
        extractingFromRTSPURL(urlString).url
    }

    /// Whether a stream URI an ONVIF camera reported is split at its last `@`, as
    /// `extractingFromRTSPURL` splits a URL with ambiguous userinfo (see
    /// `hasAmbiguousUserInfo`), leaving a host after it. That `@` ends the login when
    /// no `/` or `?` comes before it, since then it can't be in a path or a query
    /// (`rtsp://admin:p#ss@192.0.2.20/s`, `rtsp://user:1234#ab@192.0.2.20/s`). When one
    /// does, the `@` may be part of the address, as in a login in the query
    /// (`rtsp://192.0.2.5:554/live?password=Adm1n@2024`), where splitting would leave
    /// the end of the password as the host; such a URI is split only when the host
    /// after the `@` is `onvifHost`, the camera that reported it
    /// (`rtsp://admin:1234/5@192.0.2.5/s`). A camera saved by a name
    /// (`frontdoor.local`) usually reports its IP address, so the host alone can't
    /// decide every URI. The same rule decides what is saved
    /// (`strippingUserInfo(fromReportedURI:onvifHost:)`) and what is connected to
    /// (`StreamCoordinator.connectionTarget`), so they can't disagree.
    ///
    /// The host is `URLComponents`' when it can parse the URI. When it can't (a `#`
    /// or `?` in the password: `rtsp://user:p#ss@192.0.2.5/s`, or a space in a query
    /// on some macOS versions) it is read by hand: a bracketed IPv6 literal, or the
    /// text up to the first `:`, `/`, `?` or `#`. IP literals compare by value, names
    /// without case.
    static func splitsAtLastAt(reportedURI uri: String, onvifHost: String) -> Bool {
        guard let split = AmbiguousUserInfo(uri) else { return false }
        let host = URLComponents(string: uri) != nil
            ? URLComponents(string: split.urlWithout)?.host
            : leadingHost(of: split.urlWithout)
        guard let host else { return false }
        return !split.mayBeInPathOrQuery || comparableHost(host) == comparableHost(onvifHost)
    }

    /// A stream URI an ONVIF camera at `onvifHost` reported, without the login some
    /// cameras put in its userinfo, for saving as the camera's fallback URI. It is
    /// split at its last `@` only when `splitsAtLastAt(reportedURI:onvifHost:)` says
    /// so; otherwise only the userinfo `URLComponents` reads is removed, and an `@`
    /// in the path or query stays where it is. Nil for a URI `URLComponents` can't
    /// read that is not split: a login in it could not be taken out, and nothing could
    /// connect to it anyway.
    static func strippingUserInfo(fromReportedURI uri: String, onvifHost: String) -> String? {
        guard hasAmbiguousUserInfo(uri), !splitsAtLastAt(reportedURI: uri, onvifHost: onvifHost) else {
            return strippingUserInfo(from: uri)
        }
        guard URLComponents(string: uri) != nil else { return nil }
        return extractingReadableLogin(from: uri).url
    }

    /// Whether `urlString` has an `@` after its host that may end a user name or
    /// password, so `URLComponents` can't be trusted to find its host. IPCamKit refuses
    /// to connect to such a URL (its `checkAmbiguousUserInfo`), and the add/edit form
    /// rejects it with an explanation.
    static func hasAmbiguousUserInfo(_ urlString: String) -> Bool {
        AmbiguousUserInfo(urlString) != nil
    }
}

private extension SourceCredentials {
    /// The userinfo `URLComponents` reads, taken out of `urlString`.
    static func extractingReadableLogin(from urlString: String) -> (url: String, login: URLLogin?) {
        guard var components = URLComponents(string: urlString),
              components.user != nil || components.password != nil else {
            return (urlString, nil)
        }
        let login = URLLogin(username: components.user ?? "", password: components.password)
        components.user = nil
        components.password = nil
        return (components.string ?? urlString, login)
    }

    /// The host at the start of `url`'s authority, read by hand: a bracketed IPv6
    /// literal (brackets kept), or the text up to the first `:`, `/`, `?` or `#`. Nil
    /// when there is none.
    static func leadingHost(of url: String) -> String? {
        guard let separator = url.range(of: "://") else { return nil }
        let authority = url[separator.upperBound...]
        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else { return nil }
            return String(authority[...close])
        }
        let host = authority.prefix { !":/?#".contains($0) }
        return host.isEmpty ? nil : String(host)
    }

    /// IP literals by value (`::ffff:192.0.2.5` is `192.0.2.5`; brackets and zone
    /// ignored, see `ONVIFDiscovery.normalizedIPAddress`), names without case or brackets.
    static func comparableHost(_ host: String) -> String {
        if let address = ONVIFDiscovery.normalizedIPAddress(host) { return address }
        var trimmed = Substring(host)
        if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
            trimmed = trimmed.dropFirst().dropLast()
        }
        return trimmed.lowercased()
    }
}

/// The parts of a login an RTSP URL's userinfo holds (see
/// `SourceCredentials.extractingLoginFromRTSPURL`). A missing part is nil.
internal struct URLLogin: Equatable {
    let username: String?
    let password: String?

    /// Nil when the URL holds no part of a login: an empty user name and no password,
    /// or an empty one.
    init?(username: String, password: String?) {
        guard !username.isEmpty || !(password ?? "").isEmpty else { return nil }
        self.username = username.isEmpty ? nil : username
        self.password = password
    }

    /// The login as credentials, with a missing part empty.
    var credentials: SourceCredentials {
        SourceCredentials(username: username ?? "", password: password ?? "")
    }
}

/// What saving a source does to its stored credentials.
internal enum CredentialChange: Equatable {
    /// Leave whatever is stored untouched.
    case keep
    case set(SourceCredentials)
    case remove

    /// The change the add/edit form asks for. Credentials are only removed when the
    /// form knows what was stored: if reading them failed, the form never showed
    /// them, so leaving authentication off must not delete them. A password with an
    /// empty user name is kept, since an RTSP URL can carry exactly that.
    static func fromForm(
        authenticationEnabled: Bool, username: String, password: String, storedCredentialsUnreadable: Bool
    ) -> Self {
        if authenticationEnabled && !(username.isEmpty && password.isEmpty) {
            return .set(SourceCredentials(username: username, password: password))
        }
        return storedCredentialsUnreadable ? .keep : .remove
    }

    /// This change with the login an edited RTSP URL holds. The edit form shows the
    /// saved URL without credentials and fills its fields with the saved ones, so a
    /// login in the URL was just typed or pasted and is the newest input. But it is
    /// often only part of one: pasting `rtsp://admin@192.168.1.6/s` to change the
    /// address replaced the saved password with an empty one. So the URL wins only for
    /// the parts it holds; a part it lacks is the form's, or, when the form keeps what
    /// is stored (`.keep`), the stored one. `stored` is called only in that case.
    func merging(_ login: URLLogin?, stored: () throws -> SourceCredentials?) rethrows -> Self {
        guard let login else { return self }
        guard login.username == nil || login.password == nil else { return .set(login.credentials) }
        let other: SourceCredentials?
        switch self {
        case .set(let entered): other = entered
        case .keep: other = try stored()
        case .remove: other = nil
        }
        return .set(SourceCredentials(
            username: login.username ?? other?.username ?? "",
            password: login.password ?? other?.password ?? ""
        ))
    }
}

/// The userinfo of a URL whose `user:password@` `URLComponents` can't read: everything
/// between `://` and the last `@`. Applies when `URLComponents` fails on a URL that has
/// an `@` after `://` (a `#` or `?` in the password), and when it parses the URL but
/// IPCamKit's ambiguity rule fires: an `@` after the end of the authority, together
/// with userinfo or a port in the authority (how a password's start reads) or a `:`
/// between the authority and that `@`. Works on Unicode scalars, as `URLComponents`
/// does, so a combining mark after a delimiter can't hide it.
private struct AmbiguousUserInfo {
    let urlWithout: String
    let login: URLLogin?
    /// Whether a `/` or `?` comes before the last `@`, so that `@` may be in a path or
    /// a query rather than end a login.
    let mayBeInPathOrQuery: Bool

    init?(_ urlString: String) {
        let scalars = urlString.unicodeScalars
        guard let separator = urlString.utf8.firstRange(of: "://".utf8) else { return nil }
        let rest = scalars[separator.upperBound...]
        guard let lastAt = rest.lastIndex(of: "@") else { return nil }

        if URLComponents(string: urlString) != nil {
            guard let authorityEnd = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }),
                  lastAt > authorityEnd else { return nil }
            let authority = rest[..<authorityEnd]
            guard authority.contains("@")
                    || (authority.first != "[" && authority.contains(":"))
                    || rest[authorityEnd..<lastAt].contains(":") else { return nil }
        }

        let userInfo = rest[..<lastAt]
        mayBeInPathOrQuery = userInfo.contains { $0 == "/" || $0 == "?" }
        urlWithout = String(scalars[..<separator.upperBound]) + String(rest[rest.index(after: lastAt)...])
        let user: Substring.UnicodeScalarView
        let password: Substring.UnicodeScalarView?
        if let colon = userInfo.firstIndex(of: ":") {
            user = userInfo[..<colon]
            password = userInfo[userInfo.index(after: colon)...]
        } else {
            user = userInfo
            password = nil
        }
        login = URLLogin(username: Self.decoded(user), password: password.map(Self.decoded))
    }

    /// Percent-decoded, or as written when it is not valid percent-encoding (a raw `%`).
    private static func decoded(_ part: Substring.UnicodeScalarView) -> String {
        let text = String(part)
        return text.removingPercentEncoding ?? text
    }
}

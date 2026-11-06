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
    /// (`rtsp://:secret@host`); credentials are nil when both parts are empty. A URL
    /// that can't be parsed is returned unchanged.
    static func extractingFromRTSPURL(
        _ urlString: String
    ) -> (url: String, credentials: SourceCredentials?) {
        guard var components = URLComponents(string: urlString),
              components.user != nil || components.password != nil else {
            return (urlString, nil)
        }
        let user = components.user ?? ""
        let password = components.password ?? ""
        components.user = nil
        components.password = nil
        let cleaned = components.string ?? urlString
        let credentials = user.isEmpty && password.isEmpty
            ? nil : SourceCredentials(username: user, password: password)
        return (cleaned, credentials)
    }

    /// `urlString` without any userinfo, for display and for URLs whose embedded
    /// credentials are not wanted (such as a stream URI a camera reports).
    static func strippingUserInfo(from urlString: String) -> String {
        extractingFromRTSPURL(urlString).url
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
}

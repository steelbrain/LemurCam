import Foundation

internal struct SourceCredentials: Equatable {
    var username: String
    var password: String
}

internal extension SourceCredentials {
    /// Split any `user:password@` userinfo out of an RTSP(S) URL so credentials are
    /// never persisted inside the stored URL string — they belong in the Keychain.
    /// Returns the URL with userinfo removed and the extracted credentials (nil when the
    /// URL carried none, or could not be parsed, in which case the URL is returned
    /// unchanged). Only rewrites the URL when credentials were actually present.
    static func extractingFromRTSPURL(
        _ urlString: String
    ) -> (url: String, credentials: SourceCredentials?) {
        guard var components = URLComponents(string: urlString),
              let user = components.user, !user.isEmpty else {
            return (urlString, nil)
        }
        let password = components.password ?? ""
        components.user = nil
        components.password = nil
        let cleaned = components.string ?? urlString
        return (cleaned, SourceCredentials(username: user, password: password))
    }
}

import Foundation

/// A camera URL as the app shows it in labels and subtitles, which the user can
/// select and copy. Saved URLs hold no `user:password@` (it goes to the Keychain), but
/// some cameras take their login in the path or the query instead: Xiongmai's
/// `/user=admin_password=…_channel=1…`, or `?user=admin&password=…`. Those values are
/// shown as `***`, by the rules IPCamKit applies to the URLs in its messages (its
/// `redactingCredentialParameters`, which it does not export).
///
/// Only what is shown changes. The URL that is saved and connected to keeps the
/// values, and so does a field the user edits, where `***` would be saved.
internal enum DisplayedURL {
    /// `url` without its userinfo, and with the values of credential-like parameters
    /// replaced by `***`. A URL `URLComponents` reads, but with an `@` after its host
    /// (see `SourceCredentials.hasAmbiguousUserInfo`), has its parameters hidden
    /// first: that `@` may be inside a login in the query or path
    /// (`?user=admin&password=Adm1n@2024`), where the hidden value takes it along, and
    /// cutting at it would show the end of the password in place of the address.
    /// Any other URL loses its userinfo first, split at its last `@` when
    /// `URLComponents` can't read it.
    static func redacted(_ url: String) -> String {
        guard URLComponents(cameraURL: url) != nil, SourceCredentials.hasAmbiguousUserInfo(url) else {
            return redactingCredentialParameters(SourceCredentials.strippingUserInfo(from: url))
        }
        return SourceCredentials.strippingUserInfo(from: redactingCredentialParameters(url))
    }

    /// Whether URL parameter name `raw` looks like it holds a credential: after
    /// percent-decoding and in any case, it contains user, pass, pwd, auth, token or
    /// secret, or is one of the CGI names usr, pw, psw, loginuse and loginpas.
    static func isCredentialParameterName(_ raw: some StringProtocol) -> Bool {
        let name = (raw.removingPercentEncoding ?? String(raw)).lowercased()
        return ["user", "pass", "pwd", "auth", "token", "secret"].contains { name.contains($0) }
            || ["usr", "pw", "psw", "loginuse", "loginpas"].contains(name)
    }

    /// `url` with the values of credential-like parameters (`isCredentialParameterName`)
    /// replaced by `***`. A parameter after `?`, `&` or `;` is hidden after its `=` up
    /// to the next `&` or `#` (a `;` may be part of a password); one that starts a path
    /// segment, up to the next `/`, `?` or `#`. Read as Unicode scalars, so a separator
    /// that a combining mark follows still separates.
    static func redactingCredentialParameters(_ url: String) -> String {
        let scalars = Array(url.unicodeScalars)
        let nameStops: Set<Unicode.Scalar> = ["=", "?", "&", ";", "#", "/"]
        var result: [Unicode.Scalar] = []
        result.reserveCapacity(scalars.count)
        var index = 0
        while index < scalars.count {
            let separator = scalars[index]
            result.append(separator)
            index += 1
            let inQuery = separator == "?" || separator == "&" || separator == ";"
            guard inQuery || separator == "/" else { continue }
            // The name runs to `=`; another separator first means there is none here
            // (that separator starts its own name).
            var equals = index
            while equals < scalars.count, !nameStops.contains(scalars[equals]) { equals += 1 }
            guard equals < scalars.count, scalars[equals] == "=",
                  isCredentialParameterName(String(String.UnicodeScalarView(scalars[index..<equals]))) else { continue }
            result.append(contentsOf: scalars[index...equals])
            result.append(contentsOf: "***".unicodeScalars)
            let valueStops: Set<Unicode.Scalar> = inQuery ? ["&", "#"] : ["/", "?", "#"]
            index = equals + 1
            while index < scalars.count, !valueStops.contains(scalars[index]) { index += 1 }
        }
        return String(String.UnicodeScalarView(result))
    }
}

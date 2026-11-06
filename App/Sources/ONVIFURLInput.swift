import Foundation

/// Reads the ONVIF URL typed into the add form (`http://192.168.1.64/onvif/device_service`).
/// Its host was taken percent-decoded and never checked, so
/// `http://admin%3Asecret%40192.168.1.64/onvif/device_service` made the host
/// `admin:secret@192.168.1.64`: Fetch Profiles worked, and the login was saved in the
/// cameras file and shown in the camera list. The host now has to pass the check the
/// edit form's Host field makes (`ONVIFHostInput`). That field's messages name it and
/// its Port field, which the add form doesn't have, so the add form says its own.
internal enum ONVIFURLInput {
    static let invalidMessage = "Invalid ONVIF URL"

    static let loginMessage =
        "Remove the user name and password from the URL, and enter them under Requires Authentication."

    static let notAnAddressMessage =
        "The camera's address in this URL isn't valid. Write it as an IP address or host name, as in "
            + "http://192.168.1.64:8080/onvif/device_service."

    struct Address: Equatable {
        let host: String
        let port: Int
        let useHTTPS: Bool
    }

    struct Problem: Error, Equatable {
        let message: String
    }

    /// The camera's address in `url`, read as every camera URL is
    /// (`URLComponents(cameraURL:)`), with the URL's port or the scheme's default one;
    /// or what to tell the user. A URL whose login holds a raw `/`, `?`, `#` or `@` is
    /// refused as the RTSP field refuses it (`SourceCredentials.hasAmbiguousUserInfo`):
    /// `http://admin:1234/5@192.168.1.64/onvif/device_service` read as host `admin` and
    /// port 1234, and Fetch Profiles sent the form's login there.
    static func address(in url: String) -> Result<Address, Problem> {
        if SourceCredentials.hasAmbiguousUserInfo(url) {
            return .failure(Problem(message: RTSPURLInput.ambiguousUserInfoMessage))
        }
        guard let components = URLComponents(cameraURL: url), let host = components.host, !host.isEmpty else {
            return .failure(Problem(message: invalidMessage))
        }
        if ONVIFHostInput.problem(with: host) != nil {
            return .failure(Problem(message: host.unicodeScalars.contains("@") ? loginMessage : notAnAddressMessage))
        }
        let useHTTPS = components.scheme?.lowercased() == "https"
        let port = components.port ?? (useHTTPS ? Tuning.defaultHTTPSPort : Tuning.defaultHTTPPort)
        return .success(Address(host: host, port: port, useHTTPS: useHTTPS))
    }
}

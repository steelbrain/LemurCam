import Foundation

/// Reads the ONVIF URL typed into the add form (`http://192.168.1.64/onvif/device_service`).
/// Its host was taken percent-decoded and never checked, so
/// `http://admin%3Asecret%40192.168.1.64/onvif/device_service` made the host
/// `admin:secret@192.168.1.64`: Fetch Profiles worked, and the login was saved in the
/// cameras file and shown in the camera list. The host now has to pass the check the
/// edit form's Host field makes (`ONVIFHostInput`).
internal enum ONVIFURLInput {
    static let invalidMessage = "Invalid ONVIF URL"

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
    /// or what to tell the user.
    static func address(in url: String) -> Result<Address, Problem> {
        guard let components = URLComponents(cameraURL: url), let host = components.host, !host.isEmpty else {
            return .failure(Problem(message: invalidMessage))
        }
        if let problem = ONVIFHostInput.problem(with: host) { return .failure(Problem(message: problem)) }
        let useHTTPS = components.scheme?.lowercased() == "https"
        let port = components.port ?? (useHTTPS ? Tuning.defaultHTTPSPort : Tuning.defaultHTTPPort)
        return .success(Address(host: host, port: port, useHTTPS: useHTTPS))
    }
}

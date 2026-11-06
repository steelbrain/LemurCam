import Foundation

internal extension URLComponents {
    /// A camera URL read as IPCamKit reads one it connects to (its `splitUserInfo` and
    /// `asciiURL`): with every non-ASCII character percent-encoded first
    /// (`percentEncodingNonASCII`). `URLComponents(string:)` encodes a component that
    /// holds a raw non-ASCII character itself, but then encodes the `%` of the escapes
    /// already in it too: `rtsp://admin:pw@cam/caméra%20one` reads as the path
    /// `/cam%C3%A9ra%2520one`, and the password in `admin:Grüße%2F1@` as `Grüße%2F1`,
    /// where IPCamKit reads `/cam%C3%A9ra%20one` and `Grüße/1`. Every camera URL the
    /// app saves, connects to or takes a login out of is read this way, so it means
    /// what it means to IPCamKit.
    init?(cameraURL url: String) {
        self.init(string: Self.percentEncodingNonASCII(url))
    }

    /// `url` with every non-ASCII scalar written as the percent-encoded bytes of its
    /// UTF-8, and nothing else changed: IPCamKit's `percentEncodingNonASCII`, which it
    /// does not export.
    static func percentEncodingNonASCII(_ url: String) -> String {
        guard !url.unicodeScalars.allSatisfy(\.isASCII) else { return url }
        var encoded = ""
        for scalar in url.unicodeScalars {
            if scalar.isASCII {
                encoded.unicodeScalars.append(scalar)
            } else {
                for byte in String(scalar).utf8 { encoded += String(format: "%%%02X", byte) }
            }
        }
        return encoded
    }
}

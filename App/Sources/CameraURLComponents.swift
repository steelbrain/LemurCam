import Foundation

internal extension URLComponents {
    /// A camera URL read with each escape in it decoded once, as the user meant it.
    /// `URLComponents(string:)` percent-encodes a component holding a character that
    /// can't stand raw in it, but then encodes the `%` of the escapes already there
    /// too: the password in `admin:Grüße%2F1@` read as `Grüße%2F1`, the one in
    /// `admin:P|ss%40word@` as `P|ss%40word`, and the path `/caméra%20one` as
    /// `/cam%C3%A9ra%2520one`. So each such character is written as an escape first
    /// (`percentEncodingForParsing`): `Grüße/1`, `P|ss@word`, `/cam%C3%A9ra%20one`.
    /// Non-ASCII characters aside, the host and port are left as written, which is how
    /// IPCamKit reads them. IPCamKit reads a login in a URL with the same double
    /// encoding, but the app takes the login out and passes it to IPCamKit on its own.
    /// Every camera URL the app saves, connects to or takes a login out of is read
    /// this way.
    init?(cameraURL url: String) {
        self.init(string: Self.percentEncodingForParsing(url))
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

    /// `url` with each character `URLComponents` would percent-encode itself written as
    /// an escape, so the escapes already in it are not encoded again: non-ASCII
    /// characters (`percentEncodingNonASCII`); spaces and control characters; `"`,
    /// `<`, `>`, `[`, `\`, `]`, `^`, `` ` ``, `{`, `|` and `}`; a `%` not followed by
    /// two hex digits; in the userinfo, an `@` (it ends at the last one before the
    /// host) and every `:` after the first (which ends the user name); and in the
    /// fragment, a `#`. Otherwise the scheme, host and port are left as written: the
    /// brackets and zone of an IPv6 host (`[fe80::1%en0]`) belong there, and a
    /// character a host can't hold must keep the URL unreadable, as it is to IPCamKit.
    /// Only non-ASCII characters are encoded in a URL without a `scheme://`.
    static func percentEncodingForParsing(_ url: String) -> String {
        let ascii = percentEncodingNonASCII(url)
        let bytes = Array(ascii.utf8)
        guard let layout = CameraURLLayout(bytes) else { return ascii }
        var encoded = ""
        for (index, byte) in bytes.enumerated() {
            if layout.needsEscape(at: index) {
                encoded += String(format: "%%%02X", byte)
            } else {
                encoded.unicodeScalars.append(Unicode.Scalar(byte))
            }
        }
        return encoded
    }
}

/// Where the parts of an ASCII URL with a `scheme://` start and end, found as
/// `URLComponents` finds them: the authority ends at the first `/`, `?` or `#`, its
/// userinfo at the last `@` in it, the user name at the userinfo's first `:`, and the
/// fragment starts at the first `#`.
private struct CameraURLLayout {
    let bytes: [UInt8]
    /// Where the userinfo starts, or the host when there is none.
    let authorityStart: Int
    /// The `@` that ends the userinfo, or `authorityStart` when there is none.
    let userInfoEnd: Int
    let authorityEnd: Int
    let userEnd: Int?
    let fragmentStart: Int?

    /// Nil without a `scheme://` at the start.
    init?(_ bytes: [UInt8]) {
        guard let separator = bytes.firstRange(of: Array("://".utf8)),
              Self.isScheme(bytes[..<separator.lowerBound]) else { return nil }
        self.bytes = bytes
        authorityStart = separator.upperBound
        authorityEnd = bytes[authorityStart...].firstIndex { "/?#".utf8.contains($0) } ?? bytes.endIndex
        userInfoEnd = bytes[authorityStart..<authorityEnd].lastIndex(of: UInt8(ascii: "@")) ?? authorityStart
        userEnd = bytes[authorityStart..<userInfoEnd].firstIndex(of: UInt8(ascii: ":"))
        fragmentStart = bytes[authorityStart...].firstIndex(of: UInt8(ascii: "#"))
    }

    /// Whether the byte at `index` is one `URLComponents` would percent-encode.
    func needsEscape(at index: Int) -> Bool {
        let byte = bytes[index]
        // The host and port, and the `@` before them.
        if index < authorityStart || (userInfoEnd..<authorityEnd).contains(index) { return false }
        if byte == UInt8(ascii: "%") {
            return !(index + 2 < bytes.count && Self.isHexDigit(bytes[index + 1]) && Self.isHexDigit(bytes[index + 2]))
        }
        if index < userInfoEnd, byte == UInt8(ascii: "@") || byte == UInt8(ascii: ":") { return index != userEnd }
        if let fragmentStart, index > fragmentStart, byte == UInt8(ascii: "#") { return true }
        return byte <= 0x20 || byte >= 0x7F || "\"<>[\\]^`{|}".utf8.contains(byte)
    }

    /// Whether `bytes` are a URL scheme: a letter, then letters, digits, `+`, `-` or `.`.
    private static func isScheme(_ bytes: ArraySlice<UInt8>) -> Bool {
        guard let first = bytes.first, isLetter(first) else { return false }
        return bytes.allSatisfy { isLetter($0) || isDigit($0) || "+-.".utf8.contains($0) }
    }

    private static func isLetter(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte | 0x20)
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        isDigit(byte) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte | 0x20)
    }
}

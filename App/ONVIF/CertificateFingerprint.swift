import CryptoKit
import Foundation
import Security

/// The SHA-256 digest of a certificate's DER encoding. Two certificates with the same
/// fingerprint are the same certificate, whatever host presents them.
internal struct CertificateFingerprint: Hashable, Sendable {
    /// The 32 bytes of the digest.
    let digest: Data

    init(certificateData: Data) {
        digest = Data(SHA256.hash(data: certificateData))
    }

    init(certificate: SecCertificate) {
        self.init(certificateData: SecCertificateCopyData(certificate) as Data)
    }

    /// Reads 64 hex digits, in either case, with or without a `:` between each pair
    /// (as `formatted` writes them). Nil for anything else.
    init?(_ text: String) {
        let hex = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ":", with: "")
        guard hex.count == 64, hex.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        var bytes = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        digest = bytes
    }

    /// Uppercase hex with a `:` between bytes, as
    /// `openssl x509 -noout -fingerprint -sha256` prints it, so the user can compare
    /// it with what the camera's settings page or `openssl` shows.
    var formatted: String {
        digest.map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}

/// Saved as `formatted`. A saved value that isn't a fingerprint fails to decode.
extension CertificateFingerprint: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let fingerprint = Self(text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a SHA-256 fingerprint")
        }
        self = fingerprint
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(formatted)
    }
}

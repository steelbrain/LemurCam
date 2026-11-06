import Foundation
import XMLKit

// Internal (not private) so `@testable` unit tests can exercise the parsing with
// canned responses.
internal extension ONVIFClient {
    /// The path (and query) of the media service address in a GetCapabilities
    /// response, or nil when the response lists no usable media address.
    static func parseMediaServicePath(_ data: Data) -> String? {
        guard let root = try? ONVIFXML.parse(data) else { return nil }
        var xaddr: String?
        root.findElements(named: "Media") { media in
            if xaddr == nil { xaddr = media["XAddr"]?.getText() }
        }
        return xaddr.flatMap(servicePath(fromXAddr:))
    }

    /// `/onvif/Media` from `http://192.0.2.7:8080/onvif/Media`. Nil unless the
    /// address is an absolute URL with a path.
    static func servicePath(fromXAddr xaddr: String) -> String? {
        let trimmed = xaddr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme != nil, components.host != nil else { return nil }
        let path = components.percentEncodedPath
        guard path.hasPrefix("/") else { return nil }
        if let query = components.percentEncodedQuery, !query.isEmpty {
            return "\(path)?\(query)"
        }
        return path
    }
}

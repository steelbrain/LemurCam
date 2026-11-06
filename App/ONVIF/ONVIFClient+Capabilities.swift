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

    /// Whether a reply says the request was not authorized: HTTP 401, or a SOAP fault
    /// whose subcode is ONVIF's `ter:NotAuthorized`. To an unsigned request that means
    /// it needs authentication; to a signed one, that the credentials were refused.
    static func refusesUnauthenticated(_ data: Data, response: URLResponse) -> Bool {
        if (response as? HTTPURLResponse)?.statusCode == 401 { return true }
        guard let root = try? ONVIFXML.parse(data) else { return false }
        var notAuthorized = false
        root.findElements(named: "Fault") { fault in
            // Subcodes nest: Code > Subcode > Subcode ...; any level may name it.
            var subcode = fault["Code"]?["Subcode"]
            while let current = subcode, !notAuthorized {
                let value = current["Value"]?.getText()?.trimmingCharacters(in: .whitespacesAndNewlines)
                notAuthorized = value?.split(separator: ":").last == "NotAuthorized"
                subcode = current["Subcode"]
            }
        }
        return notAuthorized
    }

    /// The GUID from a GetEndpointReference response, without a `urn:uuid:` prefix,
    /// in the form `ONVIFDiscovery` uses for endpoint UUIDs.
    static func parseEndpointReference(_ data: Data) -> String? {
        guard let root = try? ONVIFXML.parse(data) else { return nil }
        var guid: String?
        root.findElements(named: "GUID") { element in
            if guid == nil { guid = element.getText() }
        }
        let cleaned = guid?.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "urn:uuid:", with: "")
        return cleaned.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// `/onvif/Media` from `http://192.0.2.7:8080/onvif/Media`. Nil unless the
    /// address is an absolute URL with a path.
    static func servicePath(fromXAddr xaddr: String) -> String? {
        let trimmed = xaddr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(cameraURL: trimmed),
              components.scheme != nil, components.host != nil else { return nil }
        let path = components.percentEncodedPath
        guard path.hasPrefix("/") else { return nil }
        if let query = components.percentEncodedQuery, !query.isEmpty {
            return "\(path)?\(query)"
        }
        return path
    }
}

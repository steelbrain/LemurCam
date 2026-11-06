import CryptoKit
import Foundation
import XMLKit

/// Builds the SOAP 1.2 envelopes `ONVIFClient` sends.
///
/// XMLKit's writer ignores `XMLElement.namespace`: an element is only qualified when
/// it carries a `prefix` that an ancestor declares in `namespaces`. Every element here
/// therefore gets a prefix, and the Envelope declares all of them once. (Declaring a
/// default namespace on a child instead would make the writer emit `xmlns:s=""`,
/// which is not legal XML.)
internal enum ONVIFSOAP {
    enum Namespace {
        static let soap = "http://www.w3.org/2003/05/soap-envelope"
        static let device = "http://www.onvif.org/ver10/device/wsdl"
        static let media = "http://www.onvif.org/ver10/media/wsdl"
        static let schema = "http://www.onvif.org/ver10/schema"
        static let wsse = "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd"
        static let wsu = "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd"
    }

    enum Prefix {
        static let soap = "s"
        static let device = "tds"
        static let media = "trt"
        static let schema = "tt"
        static let wsse = "wsse"
        static let wsu = "wsu"
    }

    /// The inputs of a WS-Security UsernameToken with a password digest.
    struct UsernameToken {
        let username: String
        let password: String
        let nonce: Data
        let created: Date
    }

    // MARK: - Request bodies

    static func getProfiles() -> XMLKit.XMLElement {
        element(Prefix.media, "GetProfiles")
    }

    static func getDeviceInformation() -> XMLKit.XMLElement {
        element(Prefix.device, "GetDeviceInformation")
    }

    static func getSystemDateAndTime() -> XMLKit.XMLElement {
        element(Prefix.device, "GetSystemDateAndTime")
    }

    static func getEndpointReference() -> XMLKit.XMLElement {
        element(Prefix.device, "GetEndpointReference")
    }

    static func getMediaCapabilities() -> XMLKit.XMLElement {
        element(Prefix.device, "GetCapabilities") {
            element(Prefix.device, "Category") { "Media" }
        }
    }

    static func getStreamURI(profileToken: String) -> XMLKit.XMLElement {
        element(Prefix.media, "GetStreamUri") {
            element(Prefix.media, "StreamSetup") {
                element(Prefix.schema, "Stream") { "RTP-Unicast" }
                element(Prefix.schema, "Transport") {
                    element(Prefix.schema, "Protocol") { "RTSP" }
                }
            }
            element(Prefix.media, "ProfileToken") { profileToken }
        }
    }

    // MARK: - Envelope

    /// Wraps `body` in a SOAP Envelope, with a WS-Security header when `security`
    /// is given.
    static func envelope(body: XMLKit.XMLElement, security: UsernameToken?) -> String {
        var envelope = element(Prefix.soap, "Envelope") {
            element(Prefix.soap, "Header") {
                if let security {
                    securityHeader(security)
                }
            }
            element(Prefix.soap, "Body") { body }
        }
        envelope.namespaces = XMLNamespaceMap([
            Prefix.soap: Namespace.soap,
            Prefix.device: Namespace.device,
            Prefix.media: Namespace.media,
            Prefix.schema: Namespace.schema,
            Prefix.wsse: Namespace.wsse,
            Prefix.wsu: Namespace.wsu
        ])
        return envelope.write()
    }

    static func securityHeader(_ token: UsernameToken) -> XMLKit.XMLElement {
        let created = timestamp(token.created)
        let digest = passwordDigest(nonce: token.nonce, created: created, password: token.password)
        var security = element(Prefix.wsse, "Security") {
            element(Prefix.wsse, "UsernameToken") {
                element(Prefix.wsse, "Username") { token.username }
                element(Prefix.wsse, "Password", attributes: [
                    "Type": "http://docs.oasis-open.org/wss/2004/01/"
                        + "oasis-200401-wss-username-token-profile-1.0#PasswordDigest"
                ]) { digest }
                element(Prefix.wsse, "Nonce", attributes: [
                    "EncodingType": "http://docs.oasis-open.org/wss/2004/01/"
                        + "oasis-200401-wss-soap-message-security-1.0#Base64Binary"
                ]) { token.nonce.base64EncodedString() }
                element(Prefix.wsu, "Created") { created }
            }
        }
        security.attributes["\(Prefix.soap):mustUnderstand"] = "true"
        return security
    }

    /// `Created` timestamp in the form WS-Security expects, e.g. `2026-01-02T03:04:05Z`.
    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// Digest = Base64(SHA1(nonce + created + password)).
    static func passwordDigest(nonce: Data, created: String, password: String) -> String {
        var input = Data()
        input.append(nonce)
        input.append(Data(created.utf8))
        input.append(Data(password.utf8))
        return Data(Insecure.SHA1.hash(data: input)).base64EncodedString()
    }

    // MARK: - Element helpers

    static func element(
        _ prefix: String, _ name: String,
        attributes: [String: String] = [:],
        @XMLBuilder content: () -> [XMLKit.XMLNode]
    ) -> XMLKit.XMLElement {
        var element = XMLKit.XMLElement.build(name, attributes: attributes, content: content)
        element.prefix = prefix
        return element
    }

    static func element(_ prefix: String, _ name: String) -> XMLKit.XMLElement {
        var element = XMLKit.XMLElement.build(name)
        element.prefix = prefix
        return element
    }
}

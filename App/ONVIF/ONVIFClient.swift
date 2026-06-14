import CryptoKit
import Foundation
import XMLKit

private typealias XElement = XMLKit.XMLElement
private typealias XNode = XMLKit.XMLNode

/// Sendable: every stored property is immutable and Sendable (`URLSession` is
/// itself Sendable), so instances are safe to pass into tasks.
internal final class ONVIFClient: Sendable {
    private let host: String
    private let port: Int
    private let username: String?
    private let password: String?
    private let session: URLSession

    private let useHTTPS: Bool

    init(host: String, port: Int, username: String?, password: String?, useHTTPS: Bool = false) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.useHTTPS = useHTTPS

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = Tuning.onvifRequestTimeout
        self.session = URLSession(configuration: config)
    }

    deinit {
        session.invalidateAndCancel()
    }

    // MARK: - Public

    func getProfiles() async throws -> [ONVIFProfile] {
        var body = XElement.build("GetProfiles")
        body.namespace = "http://www.onvif.org/ver10/media/wsdl"
        let data = try await post(path: "/onvif/media", body: buildSOAPRequest(body: body))
        return try parseProfiles(data)
    }

    func getDeviceInformation() async throws -> ONVIFDeviceInfo {
        var body = XElement.build("GetDeviceInformation")
        body.namespace = "http://www.onvif.org/ver10/device/wsdl"
        let data = try await post(path: "/onvif/device_service", body: buildSOAPRequest(body: body))
        return try parseDeviceInformation(data)
    }

    func getStreamURI(profileToken: String) async throws -> String {
        var stream = XElement.build("Stream") { "RTP-Unicast" }
        stream.namespace = "http://www.onvif.org/ver10/schema"
        var transport = XElement.build("Transport") {
            XElement.build("Protocol") { "RTSP" }
        }
        transport.namespace = "http://www.onvif.org/ver10/schema"

        let body = XElement.build("GetStreamUri") {
            XElement.build("StreamSetup") {
                stream
                transport
            }
            XElement.build("ProfileToken") { profileToken }
        }
        let data = try await post(
            path: "/onvif/media",
            body: buildSOAPRequest(body: body, bodyNamespace: "http://www.onvif.org/ver10/media/wsdl")
        )
        return try parseStreamURI(data)
    }

    // MARK: - SOAP

    private func buildSOAPRequest(body: XElement, bodyNamespace: String? = nil) -> String {
        var bodyElement = body
        if let ns = bodyNamespace {
            bodyElement.namespace = ns
        }

        var envelope = soapElement("Envelope") {
            soapElement("Header") {
                if let securityElement = buildSecurityHeader() {
                    securityElement
                }
            }
            soapElement("Body") {
                bodyElement
            }
        }
        envelope.namespaces = XMLNamespaceMap(["s": "http://www.w3.org/2003/05/soap-envelope"])
        return envelope.write()
    }

    private func soapElement(
        _ name: String,
        @XMLBuilder content: () -> [XNode]
    ) -> XElement {
        var el = XElement.build(name, content: content)
        el.prefix = "s"
        return el
    }

    private func buildSecurityHeader() -> XElement? {
        guard let username, let password, !username.isEmpty else { return nil }

        var nonceBytes = [UInt8](repeating: 0, count: 16)
        if SecRandomCopyBytes(kSecRandomDefault, nonceBytes.count, &nonceBytes) != errSecSuccess {
            for idx in nonceBytes.indices { nonceBytes[idx] = UInt8.random(in: 0...255) }
        }
        let nonceData = Data(nonceBytes)
        let nonceBase64 = nonceData.base64EncodedString()

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let created = formatter.string(from: Date())

        // Digest = Base64(SHA1(nonce + created + password))
        var digestInput = Data()
        digestInput.append(nonceData)
        digestInput.append(Data(created.utf8))
        digestInput.append(Data(password.utf8))
        let digest = Insecure.SHA1.hash(data: digestInput)
        let digestBase64 = Data(digest).base64EncodedString()

        let wsse = "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd"
        let wsu = "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd"

        var createdEl = XElement.build("Created") { created }
        createdEl.namespace = wsu

        var security = XElement.build("Security") {
            XElement.build("UsernameToken") {
                XElement.build("Username") { username }
                XElement.build("Password", attributes: [
                    "Type": "http://docs.oasis-open.org/wss/2004/01/"
                        + "oasis-200401-wss-username-token-profile-1.0#PasswordDigest"
                ]) { digestBase64 }
                XElement.build("Nonce", attributes: [
                    "EncodingType": "http://docs.oasis-open.org/wss/2004/01/"
                        + "oasis-200401-wss-soap-message-security-1.0#Base64Binary"
                ]) { nonceBase64 }
                createdEl
            }
        }
        security.namespace = wsse
        security.attributes["s:mustUnderstand"] = "true"
        return security
    }

    // MARK: - HTTP

    private func post(path: String, body: String) async throws -> Data {
        let scheme = useHTTPS ? "https" : "http"
        guard let url = URL(string: "\(scheme)://\(host):\(port)\(path)") else {
            throw ONVIFError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/soap+xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ONVIFError.networkError(error.localizedDescription)
        }

        if let httpResponse = response as? HTTPURLResponse {
            if httpResponse.statusCode == 401 {
                throw ONVIFError.authenticationFailed
            }
            if httpResponse.statusCode >= 400 {
                if let fault = extractSOAPFault(from: data) {
                    throw ONVIFError.soapFault(fault)
                }
                throw ONVIFError.networkError("HTTP \(httpResponse.statusCode)")
            }
        }

        // Check for SOAP fault even in 200 responses
        if let fault = extractSOAPFault(from: data) {
            throw ONVIFError.soapFault(fault)
        }

        return data
    }

}

// MARK: - XML Parsing

// Internal (not private) so `@testable` unit tests can reach the XML parsing
// helpers; these are pure functions exercised directly by ONVIFClientTests.
internal extension ONVIFClient {
    func parseProfiles(_ data: Data) throws -> [ONVIFProfile] {
        let root = try XElement.parse(data)
        var profiles: [ONVIFProfile] = []

        root.findElements(named: "Profiles") { profileEl in
            guard let token = profileEl.attributes["token"] else { return }
            let name = profileEl["Name"]?.getText()

            var width: Int?
            var height: Int?
            var codec: String?
            if let videoEncoder = profileEl["VideoEncoderConfiguration"] {
                if let resolution = videoEncoder["Resolution"] {
                    width = resolution["Width"]?.getText().flatMap(Int.init)
                    height = resolution["Height"]?.getText().flatMap(Int.init)
                }
                codec = videoEncoder["Encoding"]?.getText()
            }

            profiles.append(ONVIFProfile(
                token: token,
                name: name ?? token,
                width: width,
                height: height,
                codec: codec
            ))
        }

        guard !profiles.isEmpty else {
            throw ONVIFError.parseError
        }
        return profiles
    }

    func parseStreamURI(_ data: Data) throws -> String {
        let root = try XElement.parse(data)
        var uri: String?
        root.findElements(named: "Uri") { el in
            if uri == nil, let text = el.getText(), !text.isEmpty {
                uri = text
            }
        }
        guard let result = uri else {
            throw ONVIFError.parseError
        }
        return result
    }

    func parseDeviceInformation(_ data: Data) throws -> ONVIFDeviceInfo {
        let root = try XElement.parse(data)
        var info: ONVIFDeviceInfo?
        root.findElements(named: "GetDeviceInformationResponse") { el in
            info = ONVIFDeviceInfo(
                manufacturer: el["Manufacturer"]?.getText(),
                model: el["Model"]?.getText(),
                firmwareVersion: el["FirmwareVersion"]?.getText(),
                serialNumber: el["SerialNumber"]?.getText(),
                hardwareId: el["HardwareId"]?.getText()
            )
        }
        return info ?? ONVIFDeviceInfo(
            manufacturer: nil, model: nil, firmwareVersion: nil,
            serialNumber: nil, hardwareId: nil
        )
    }

    func extractSOAPFault(from data: Data) -> String? {
        guard let root = try? XElement.parse(data) else { return nil }
        var faultReason: String?
        root.findElements(named: "Fault") { fault in
            if let reason = fault["Reason"], let text = reason["Text"] {
                faultReason = text.getText()
            }
        }
        return faultReason
    }
}

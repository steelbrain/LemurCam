import Foundation
import Security
import XMLKit

/// Sendable: every stored property is immutable and Sendable (`URLSession` is
/// itself Sendable), so instances are safe to pass into tasks.
internal final class ONVIFClient: Sendable {
    private let host: String
    private let port: Int
    private let username: String?
    private let password: String?
    private let session: URLSession

    private let useHTTPS: Bool

    /// `configuration` exists so tests can install a stub `URLProtocol`; the app
    /// always uses the default configuration.
    init(
        host: String, port: Int, username: String?, password: String?, useHTTPS: Bool = false,
        configuration: URLSessionConfiguration = .default
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.useHTTPS = useHTTPS

        configuration.timeoutIntervalForRequest = Tuning.onvifRequestTimeout
        self.session = URLSession(configuration: configuration)
    }

    deinit {
        session.invalidateAndCancel()
    }

    // MARK: - Public

    func getProfiles() async throws -> [ONVIFProfile] {
        let data = try await post(path: "/onvif/media", body: ONVIFSOAP.getProfiles())
        return try parseProfiles(data)
    }

    func getDeviceInformation() async throws -> ONVIFDeviceInfo {
        let data = try await post(path: "/onvif/device_service", body: ONVIFSOAP.getDeviceInformation())
        return try parseDeviceInformation(data)
    }

    func getStreamURI(profileToken: String) async throws -> String {
        let data = try await post(path: "/onvif/media", body: ONVIFSOAP.getStreamURI(profileToken: profileToken))
        return try parseStreamURI(data)
    }

    // MARK: - SOAP

    /// The full SOAP envelope for `body`, signed with a fresh WS-Security
    /// UsernameToken when the client has credentials.
    func requestEnvelope(body: XMLKit.XMLElement) -> String {
        ONVIFSOAP.envelope(body: body, security: usernameToken())
    }

    private func usernameToken() -> ONVIFSOAP.UsernameToken? {
        guard let username, let password, !username.isEmpty else { return nil }
        var nonceBytes = [UInt8](repeating: 0, count: 16)
        if SecRandomCopyBytes(kSecRandomDefault, nonceBytes.count, &nonceBytes) != errSecSuccess {
            for idx in nonceBytes.indices { nonceBytes[idx] = UInt8.random(in: 0...255) }
        }
        return ONVIFSOAP.UsernameToken(
            username: username, password: password, nonce: Data(nonceBytes), created: Date()
        )
    }

    // MARK: - HTTP

    private func post(path: String, body: XMLKit.XMLElement) async throws -> Data {
        let scheme = useHTTPS ? "https" : "http"
        guard let url = URL(string: "\(scheme)://\(host):\(port)\(path)") else {
            throw ONVIFError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/soap+xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(requestEnvelope(body: body).utf8)

        let (data, response) = try await send(request)

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

    /// Reads the response body, giving up once it exceeds `ONVIFXML.maxDocumentBytes`
    /// so a hostile or broken device cannot make the app buffer an unbounded body.
    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw ONVIFError.networkError(error.localizedDescription)
        }
        let limit = ONVIFXML.maxDocumentBytes
        if response.expectedContentLength > Int64(limit) {
            bytes.task.cancel()
            throw ONVIFXML.Rejection.tooLarge
        }
        var data = Data()
        do {
            for try await byte in bytes {
                guard data.count < limit else {
                    bytes.task.cancel()
                    throw ONVIFXML.Rejection.tooLarge
                }
                data.append(byte)
            }
        } catch let rejection as ONVIFXML.Rejection {
            throw rejection
        } catch {
            throw ONVIFError.networkError(error.localizedDescription)
        }
        return (data, response)
    }
}

// MARK: - XML Parsing

// Internal (not private) so `@testable` unit tests can reach the XML parsing
// helpers; these are pure functions exercised directly by ONVIFClientTests.
internal extension ONVIFClient {
    func parseProfiles(_ data: Data) throws -> [ONVIFProfile] {
        let root = try ONVIFXML.parse(data)
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
        let root = try ONVIFXML.parse(data)
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
        let root = try ONVIFXML.parse(data)
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
        guard let root = try? ONVIFXML.parse(data) else { return nil }
        var faultReason: String?
        root.findElements(named: "Fault") { fault in
            if let reason = fault["Reason"], let text = reason["Text"] {
                faultReason = text.getText()
            }
        }
        return faultReason
    }
}

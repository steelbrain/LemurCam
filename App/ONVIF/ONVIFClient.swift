import Foundation
import os
import Security
import XMLKit

/// Sendable: every stored property is immutable and Sendable (`URLSession` is
/// itself Sendable, the cached clock offset sits behind a lock), so instances are
/// safe to pass into tasks.
internal final class ONVIFClient: Sendable {
    static let deviceServicePath = "/onvif/device_service"
    /// Where most cameras serve the media service; used when GetCapabilities does
    /// not say otherwise.
    static let defaultMediaServicePath = "/onvif/media"

    private let host: String
    private let port: Int
    private let username: String?
    private let password: String?
    private let session: URLSession

    private let useHTTPS: Bool

    /// Seconds to add to the Mac's clock to get the device's, measured once per
    /// client with GetSystemDateAndTime before the first signed request.
    private let clockOffset = OSAllocatedUnfairLock<TimeInterval?>(initialState: nil)

    /// Path of the media service, read once per client from GetCapabilities.
    private let mediaPath = OSAllocatedUnfairLock<String?>(initialState: nil)

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
        configuration.timeoutIntervalForResource = ONVIFTimeout.resource
        self.session = URLSession(configuration: configuration)
    }

    deinit {
        session.invalidateAndCancel()
    }

    // MARK: - Public

    func getProfiles() async throws -> [ONVIFProfile] {
        let data = try await post(path: mediaServicePath(), body: ONVIFSOAP.getProfiles())
        return try parseProfiles(data)
    }

    func getDeviceInformation() async throws -> ONVIFDeviceInfo {
        let data = try await post(path: Self.deviceServicePath, body: ONVIFSOAP.getDeviceInformation())
        return try parseDeviceInformation(data)
    }

    func getStreamURI(profileToken: String) async throws -> String {
        let data = try await post(path: mediaServicePath(), body: ONVIFSOAP.getStreamURI(profileToken: profileToken))
        return try parseStreamURI(data)
    }

    // MARK: - Service discovery

    /// Cameras serve the media service at vendor-specific paths (`/onvif/Media`,
    /// `/onvif/media_service`, ...), so the client asks the device service where it
    /// is. Only the path of the returned address is used: requests stay on the host
    /// and port the user configured, so a device cannot point signed requests at
    /// another host, and cameras behind port forwarding (which report their internal
    /// address) keep working. GetCapabilities needs no authentication and is sent
    /// unsigned, so a wrong password does not add a failed login.
    private func mediaServicePath() async throws -> String {
        if let cached = mediaPath.withLock({ $0 }) { return cached }
        let resolved = try await resolveMediaServicePath()
        mediaPath.withLock { $0 = resolved }
        return resolved
    }

    private func resolveMediaServicePath() async throws -> String {
        let fallback = Self.defaultMediaServicePath
        do {
            let data = try await post(
                path: Self.deviceServicePath, body: ONVIFSOAP.getMediaCapabilities(), signed: false
            )
            if let path = Self.parseMediaServicePath(data) { return path }
            Log.app.info("ONVIF device listed no media service; using \(fallback)")
        } catch let error as ONVIFError where error.isTransportFailure {
            throw error
        } catch {
            Log.app.info("ONVIF GetCapabilities failed (\(error.localizedDescription)); using \(fallback)")
        }
        return Self.defaultMediaServicePath
    }

    // MARK: - SOAP

    /// The full SOAP envelope for `body`, signed with a fresh WS-Security
    /// UsernameToken when the client has credentials. `clockOffset` shifts the
    /// token's `Created` time onto the device's clock.
    func requestEnvelope(body: XMLKit.XMLElement, clockOffset: TimeInterval = 0) -> String {
        ONVIFSOAP.envelope(body: body, security: usernameToken(clockOffset: clockOffset))
    }

    private var hasCredentials: Bool {
        guard let username, password != nil else { return false }
        return !username.isEmpty
    }

    private func usernameToken(clockOffset: TimeInterval) -> ONVIFSOAP.UsernameToken? {
        guard let username, let password, !username.isEmpty else { return nil }
        var nonceBytes = [UInt8](repeating: 0, count: 16)
        if SecRandomCopyBytes(kSecRandomDefault, nonceBytes.count, &nonceBytes) != errSecSuccess {
            for idx in nonceBytes.indices { nonceBytes[idx] = UInt8.random(in: 0...255) }
        }
        return ONVIFSOAP.UsernameToken(
            username: username, password: password, nonce: Data(nonceBytes),
            created: Date().addingTimeInterval(clockOffset)
        )
    }

    // MARK: - Device clock

    /// Cameras reject a WS-Security token whose `Created` time is far from their own
    /// clock, and many cameras keep poor time. GetSystemDateAndTime needs no
    /// authentication, so the client asks for the device's time once and signs every
    /// request on the device's clock.
    private func deviceClockOffset() async throws -> TimeInterval {
        if let cached = clockOffset.withLock({ $0 }) { return cached }
        let measured = try await measureClockOffset()
        clockOffset.withLock { $0 = measured }
        return measured
    }

    /// A device that cannot be reached throws, so callers see the same error the
    /// real request would have produced without waiting for a second timeout. A
    /// device that answers without a usable time leaves the Mac's clock in use.
    private func measureClockOffset() async throws -> TimeInterval {
        let sent = Date()
        let data: Data
        do {
            data = try await post(path: Self.deviceServicePath, body: ONVIFSOAP.getSystemDateAndTime(), signed: false)
        } catch let error as ONVIFError where error.isTransportFailure {
            throw error
        } catch {
            Log.app.info("ONVIF device did not report its time (\(error.localizedDescription)); using the Mac's clock")
            return 0
        }
        guard let deviceTime = Self.parseSystemDateAndTime(data) else {
            Log.app.info("ONVIF device sent no usable UTC time; using the Mac's clock")
            return 0
        }
        return Self.clockOffset(deviceTime: deviceTime, requestSent: sent, responseReceived: Date())
    }

    // MARK: - HTTP

    /// Sends `body` to `path`. Signed requests carry a WS-Security header when the
    /// client has credentials; the first one measures the device's clock first.
    private func post(path: String, body: XMLKit.XMLElement, signed: Bool = true) async throws -> Data {
        let scheme = useHTTPS ? "https" : "http"
        guard let url = URL(string: "\(scheme)://\(host):\(port)\(path)") else {
            throw ONVIFError.invalidURL
        }

        let envelope: String
        if signed, hasCredentials {
            envelope = requestEnvelope(body: body, clockOffset: try await deviceClockOffset())
        } else {
            envelope = ONVIFSOAP.envelope(body: body, security: nil)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/soap+xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(envelope.utf8)

        let (data, response) = try await send(request)

        if let httpResponse = response as? HTTPURLResponse {
            if httpResponse.statusCode == 401 {
                throw ONVIFError.authenticationFailed
            }
            if httpResponse.statusCode >= 400 {
                if let fault = extractSOAPFault(from: data) {
                    throw ONVIFError.soapFault(fault)
                }
                throw ONVIFError.httpStatus(httpResponse.statusCode)
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

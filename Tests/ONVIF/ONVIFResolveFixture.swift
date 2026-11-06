import Foundation
@testable import LemurCam
import os
import XCTest

/// A saved ONVIF camera, stub cameras and a stub WS-Discovery scan for exercising
/// `StreamCoordinator.attemptONVIFResolve` without any network traffic. Stubs are
/// registered by host (IP literals included) with `ONVIFStubURLProtocol`; a host with
/// no stub fails like an address where nothing answers.
@MainActor
internal final class ONVIFResolveFixture {
    nonisolated static let deviceUUID = "2b9c0b1e-0000-4000-8000-00000000c0de"
    nonisolated static let credentials = SourceCredentials(username: "viewer", password: "pw")

    let manager: SourceManager
    let store = InMemoryCredentialStore()
    private let directory: URL
    private let savedActiveID: String?
    private var stubHosts: [String] = []
    private let scans = OSAllocatedUnfairLock(initialState: 0)

    /// How many WS-Discovery scans the resolve ran.
    var scanCount: Int { scans.withLock { $0 } }

    init() {
        savedActiveID = UserDefaults.standard.string(forKey: LemurCamConfig.activeSourceKey)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        manager = SourceManager(
            storage: SourceStorage(fileURL: directory.appendingPathComponent("sources.json")), keychain: store
        )
    }

    func cleanUp() {
        stubHosts.forEach(ONVIFStubURLProtocol.unregister(host:))
        if let savedActiveID {
            UserDefaults.standard.set(savedActiveID, forKey: LemurCamConfig.activeSourceKey)
        } else {
            UserDefaults.standard.removeObject(forKey: LemurCamConfig.activeSourceKey)
        }
        try? FileManager.default.removeItem(at: directory)
    }

    /// Makes `host` answer every request with `reply`.
    func stub(host: String, _ reply: ONVIFStubURLProtocol.Reply) {
        stubHosts.append(host)
        ONVIFStubURLProtocol.register(host: host) { _, _ in reply }
    }

    func addCamera(host: String, port: Int = 80, useHTTPS: Bool = false) throws -> CameraSource {
        try manager.addSource(
            name: "Porch",
            sourceType: .onvif(ONVIFSourceInfo(
                deviceUUID: Self.deviceUUID, host: host, port: port, selectedProfileToken: "main",
                useHTTPS: useHTTPS
            )),
            credentials: Self.credentials
        )
        return try XCTUnwrap(manager.sources.last)
    }

    /// The saved `sources.json`, byte for byte.
    func savedFile() throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent("sources.json"))
    }

    /// The source's saved ONVIF settings as they are now.
    func savedInfo(_ source: CameraSource) -> ONVIFSourceInfo? {
        guard case .onvif(let info)? = manager.sources.first(where: { $0.id == source.id })?.sourceType else {
            return nil
        }
        return info
    }

    /// `whileScanning` runs during the scan, before it returns `scanResult`.
    func params(
        for source: CameraSource, scanResult: [DiscoveredDevice],
        whileScanning: @escaping @Sendable () async -> Void = {}
    ) throws -> ONVIFResolveParams {
        guard case .onvif(let info) = source.sourceType else { throw XCTSkip("expected ONVIF") }
        let scanCounter = scans
        let environment = ONVIFResolveEnvironment(
            scan: {
                scanCounter.withLock { $0 += 1 }
                await whileScanning()
                return scanResult
            },
            makeClient: { info, credentials in
                ONVIFClient(
                    host: info.host, port: info.port, username: credentials?.username,
                    password: credentials?.password, useHTTPS: info.useHTTPS,
                    configuration: ONVIFStubURLProtocol.configuration()
                )
            }
        )
        return ONVIFResolveParams(
            info: info, token: "main", credentials: Self.credentials,
            sourceID: source.id, sourceName: source.name, sourceManager: manager, environment: environment
        )
    }

    nonisolated static func device(host: String, port: Int = 80, useHTTPS: Bool = false) -> DiscoveredDevice {
        DiscoveredDevice(
            endpointUUID: deviceUUID,
            endpointURL: "\(useHTTPS ? "https" : "http")://\(host):\(port)/onvif/device_service",
            name: nil, manufacturer: nil, model: nil, host: host, port: port
        )
    }

    nonisolated static func streamURIReply(_ uri: String) -> ONVIFStubURLProtocol.Reply {
        ONVIFStubURLProtocol.Reply(body: Data("""
            <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"><s:Body>
            <GetStreamUriResponse xmlns="http://www.onvif.org/ver10/media/wsdl">
            <MediaUri><Uri>\(uri)</Uri></MediaUri></GetStreamUriResponse></s:Body></s:Envelope>
            """.utf8))
    }
}

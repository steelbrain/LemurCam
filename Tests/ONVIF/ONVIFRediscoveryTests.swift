@testable import LemurCam
import os
import XCTest

/// The rediscovery loop: after any failed GetStreamUri the resolver scanned the LAN
/// and saved the result even when the camera had not moved; saving restarted the
/// resolve, and the cycle repeated every ~5.5 s (logins, multicast scans,
/// `sources.json` and Keychain rewrites, status stuck on "connecting"). These tests
/// pin when a scan happens and when its result is saved. Scans and cameras are
/// stubbed; nothing goes on the network.
@MainActor
internal final class ONVIFRediscoveryTests: XCTestCase {
    private static let uuid = "2b9c0b1e-0000-4000-8000-00000000c0de"

    private var tempURL: URL?
    private var store: InMemoryCredentialStore?
    private var manager: SourceManager?
    private var savedActiveID: String?
    private var stubHosts: [String] = []

    override func setUp() async throws {
        try await super.setUp()
        savedActiveID = UserDefaults.standard.string(forKey: LemurCamConfig.activeSourceKey)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("sources.json")
        tempURL = url
        let credentialStore = InMemoryCredentialStore()
        store = credentialStore
        manager = SourceManager(storage: SourceStorage(fileURL: url), keychain: credentialStore)
    }

    override func tearDown() async throws {
        stubHosts.forEach(ONVIFStubURLProtocol.unregister(host:))
        if let savedActiveID {
            UserDefaults.standard.set(savedActiveID, forKey: LemurCamConfig.activeSourceKey)
        } else {
            UserDefaults.standard.removeObject(forKey: LemurCamConfig.activeSourceKey)
        }
        if let tempURL {
            try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent())
        }
        try await super.tearDown()
    }

    private func device(host: String, port: Int = 80) -> DiscoveredDevice {
        DiscoveredDevice(
            endpointUUID: Self.uuid, endpointURL: "http://\(host):\(port)/onvif/device_service",
            name: nil, manufacturer: nil, model: nil, host: host, port: port
        )
    }

    // MARK: - Address-only updates

    private func addCamera(host: String) throws -> (SourceManager, InMemoryCredentialStore, CameraSource) {
        let sourceManager = try XCTUnwrap(manager)
        let credentialStore = try XCTUnwrap(store)
        sourceManager.addSource(
            name: "Porch",
            sourceType: .onvif(ONVIFSourceInfo(
                deviceUUID: Self.uuid, host: host, port: 80, selectedProfileToken: "main"
            )),
            credentials: SourceCredentials(username: "viewer", password: "pw")
        )
        return (sourceManager, credentialStore, try XCTUnwrap(sourceManager.sources.first))
    }

    func testUnchangedAddressWritesNothing() throws {
        let (sourceManager, credentialStore, source) = try addCamera(host: "192.168.1.20")
        let fileBefore = try Data(contentsOf: try XCTUnwrap(tempURL))
        var configChanges = 0
        sourceManager.onSourceConfigChanged = { configChanges += 1 }
        let writesBefore = credentialStore.writes

        sourceManager.updateONVIFAddress(id: source.id, host: "192.168.1.20", port: 80, useHTTPS: false)

        XCTAssertEqual(sourceManager.sources.first, source)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(tempURL)), fileBefore)
        XCTAssertEqual(configChanges, 0)
        XCTAssertEqual(credentialStore.writes, writesBefore)
    }

    /// A move updates only the address; it never touches the Keychain and does not
    /// restart the resolve that found it.
    func testMovedAddressUpdatesOnlyTheAddress() throws {
        let (sourceManager, credentialStore, source) = try addCamera(host: "192.168.1.20")
        var configChanges = 0
        sourceManager.onSourceConfigChanged = { configChanges += 1 }
        let writesBefore = credentialStore.writes

        sourceManager.updateONVIFAddress(id: source.id, host: "192.168.1.31", port: 8080, useHTTPS: false)

        let updated = try XCTUnwrap(sourceManager.sources.first)
        guard case .onvif(let info) = updated.sourceType else {
            XCTFail("expected ONVIF")
            return
        }
        XCTAssertEqual(info.host, "192.168.1.31")
        XCTAssertEqual(info.port, 8080)
        XCTAssertEqual(info.selectedProfileToken, "main")
        XCTAssertEqual(updated.updatedAt, source.updatedAt)
        XCTAssertEqual(configChanges, 0)
        XCTAssertEqual(credentialStore.writes, writesBefore)
    }

    // MARK: - Resolve flow

    private final class ScanCounter: Sendable {
        private let count = OSAllocatedUnfairLock(initialState: 0)
        var value: Int { count.withLock { $0 } }
        func increment() { count.withLock { $0 += 1 } }
    }

    private func streamURIReply(_ uri: String) -> Data {
        Data("""
            <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"><s:Body>
            <GetStreamUriResponse xmlns="http://www.onvif.org/ver10/media/wsdl">
            <MediaUri><Uri>\(uri)</Uri></MediaUri></GetStreamUriResponse></s:Body></s:Envelope>
            """.utf8)
    }

    /// Registers a stub camera answering every request with `reply`.
    private func stubCamera(_ reply: ONVIFStubURLProtocol.Reply) -> String {
        let host = "onvif-rediscovery-\(UUID().uuidString).invalid"
        stubHosts.append(host)
        ONVIFStubURLProtocol.register(host: host) { _, _ in reply }
        return host
    }

    private func params(
        for source: CameraSource, scanCounter: ScanCounter, scanResult: [DiscoveredDevice]
    ) throws -> ONVIFResolveParams {
        guard case .onvif(let info) = source.sourceType else { throw XCTSkip("expected ONVIF") }
        let environment = ONVIFResolveEnvironment(
            scan: {
                scanCounter.increment()
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
            info: info, token: "main", credentials: SourceCredentials(username: "viewer", password: "pw"),
            sourceID: source.id, sourceName: source.name, sourceManager: manager, environment: environment
        )
    }

    private static func onvifError(in result: ONVIFStreamURIResult) -> ONVIFError? {
        guard case .failure(let error) = result else { return nil }
        return error as? ONVIFError
    }

    /// A rejected login means the camera was reached: no scan, nothing saved.
    func testAuthenticationFailureDoesNotScan() async throws {
        let host = stubCamera(ONVIFStubURLProtocol.Reply(status: 401))
        let (sourceManager, credentialStore, source) = try addCamera(host: host)
        let writesBefore = credentialStore.writes
        let counter = ScanCounter()

        let result = try await StreamCoordinator.attemptONVIFResolve(
            params: params(for: source, scanCounter: counter, scanResult: [device(host: "192.168.1.31")])
        )

        guard case .authenticationFailed? = Self.onvifError(in: result) else {
            XCTFail("the camera's answer must be reported, got \(result)")
            return
        }
        XCTAssertEqual(counter.value, 0)
        XCTAssertEqual(sourceManager.sources.first, source)
        XCTAssertEqual(credentialStore.writes, writesBefore)
    }

    /// The loop's trigger: the scan finds the camera where it already was. Nothing is
    /// saved, so no config change restarts the resolve.
    func testUnreachableButUnmovedDeviceSavesNothing() async throws {
        let host = "onvif-rediscovery-unregistered-\(UUID().uuidString).invalid"
        let (sourceManager, credentialStore, source) = try addCamera(host: host)
        var configChanges = 0
        sourceManager.onSourceConfigChanged = { configChanges += 1 }
        let writesBefore = credentialStore.writes
        let counter = ScanCounter()

        let result = try await StreamCoordinator.attemptONVIFResolve(
            params: params(for: source, scanCounter: counter, scanResult: [device(host: host)])
        )

        XCTAssertTrue(Self.onvifError(in: result)?.isTransportFailure ?? false, "the saved address's error is kept")
        XCTAssertEqual(counter.value, 1)
        XCTAssertEqual(sourceManager.sources.first, source)
        XCTAssertEqual(configChanges, 0)
        XCTAssertEqual(credentialStore.writes, writesBefore)
    }

    func testMovedDeviceIsSavedAndQueriedAtItsNewAddress() async throws {
        let oldHost = "onvif-rediscovery-unregistered-\(UUID().uuidString).invalid"
        let newHost = stubCamera(ONVIFStubURLProtocol.Reply(body: streamURIReply("rtsp://192.0.2.31/main")))
        let (sourceManager, credentialStore, source) = try addCamera(host: oldHost)
        let writesBefore = credentialStore.writes
        let counter = ScanCounter()

        let result = try await StreamCoordinator.attemptONVIFResolve(
            params: params(for: source, scanCounter: counter, scanResult: [device(host: newHost)])
        )

        XCTAssertEqual(try result.get(), "rtsp://192.0.2.31/main")
        guard case .onvif(let info)? = sourceManager.sources.first?.sourceType else {
            XCTFail("expected ONVIF")
            return
        }
        XCTAssertEqual(info.host, newHost)
        XCTAssertEqual(credentialStore.writes, writesBefore, "rediscovery must not rewrite credentials")
    }
}

import Foundation

/// The network operations the ONVIF resolve performs. Tests replace them so the
/// rediscovery decisions can be exercised without a multicast scan or a camera.
internal struct ONVIFResolveEnvironment: Sendable {
    var scan: @Sendable () async -> [DiscoveredDevice]
    var makeClient: @Sendable (ONVIFSourceInfo, SourceCredentials?) -> ONVIFClient

    static let live = Self(
        scan: { await ONVIFDiscovery().scan() },
        makeClient: { info, credentials in StreamCoordinator.makeONVIFClient(for: info, credentials: credentials) }
    )
}

internal struct ONVIFResolveParams {
    let info: ONVIFSourceInfo
    let token: String
    let credentials: SourceCredentials?
    let sourceID: UUID
    let sourceName: String
    weak var sourceManager: SourceManager?
    var environment = ONVIFResolveEnvironment.live
}

extension StreamCoordinator {
    static func resolveONVIFStreamURI(
        params: ONVIFResolveParams,
        timeout: TimeInterval = Tuning.onvifReconnectTimeout
    ) async -> String? {
        do {
            return try await withThrowingTaskGroup(of: String?.self) { group in
                group.addTask { try await Self.attemptONVIFResolve(params: params) }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    Log.rtsp.warning("ONVIF reconnect timed out after \(timeout)s")
                    return nil
                }
                let result = (try await group.next()).flatMap { $0 }
                group.cancelAll()
                return result
            }
        } catch {
            return nil
        }
    }

    nonisolated static func makeONVIFClient(for info: ONVIFSourceInfo, credentials: SourceCredentials?) -> ONVIFClient {
        ONVIFClient(
            host: info.host, port: info.port,
            username: credentials?.username, password: credentials?.password,
            useHTTPS: info.useHTTPS
        )
    }

    /// Asks the camera for the stream URI at its saved address. Only when that gets no
    /// answer at all does it look for the camera with WS-Discovery, and it saves the
    /// address the scan reports only when that address differs from the saved one.
    /// See `ONVIFRediscovery`.
    static func attemptONVIFResolve(params: ONVIFResolveParams) async throws -> String? {
        let client = params.environment.makeClient(params.info, params.credentials)
        do {
            return try await client.getStreamURI(profileToken: params.token)
        } catch {
            try Task.checkCancellation()
            Log.rtsp.warning("ONVIF fetch failed for '\(params.sourceName)': \(error.localizedDescription)")
            guard ONVIFRediscovery.shouldRediscover(after: error) else { return nil }
        }

        guard let uuid = params.info.deviceUUID, !uuid.isEmpty else { return nil }

        Log.rtsp.info("Scanning for device \(uuid) via WS-Discovery")
        let devices = await params.environment.scan()
        try Task.checkCancellation()

        switch ONVIFRediscovery.outcome(for: params.info, among: devices) {
        case .notFound:
            Log.rtsp.info("Device \(uuid) did not answer the scan")
            return nil
        case .ambiguous:
            Log.rtsp.warning("Several addresses claim device \(uuid); keeping the saved address")
            return nil
        case .unchanged:
            Log.rtsp.info("Device \(uuid) still answers at the saved address")
            return nil
        case .moved(let moved):
            Log.rtsp.info("Found device at \(moved.host):\(moved.port)")
            return try await connect(movedTo: moved, params: params)
        }
    }

    private static func connect(movedTo moved: ONVIFSourceInfo, params: ONVIFResolveParams) async throws -> String? {
        await MainActor.run {
            params.sourceManager?.updateONVIFAddress(
                id: params.sourceID, host: moved.host, port: moved.port, useHTTPS: moved.useHTTPS
            )
        }
        let client = params.environment.makeClient(moved, params.credentials)
        do {
            return try await client.getStreamURI(profileToken: params.token)
        } catch {
            try Task.checkCancellation()
            Log.rtsp.error("ONVIF fetch failed at new address: \(error.localizedDescription)")
            return nil
        }
    }
}

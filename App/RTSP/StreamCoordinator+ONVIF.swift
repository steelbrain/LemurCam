import Foundation

internal struct ONVIFResolveParams {
    let info: ONVIFSourceInfo
    let token: String
    let credentials: SourceCredentials?
    let sourceID: UUID
    let sourceName: String
    weak var sourceManager: SourceManager?
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

    static func makeONVIFClient(for info: ONVIFSourceInfo, credentials: SourceCredentials?) -> ONVIFClient {
        ONVIFClient(
            host: info.host, port: info.port,
            username: credentials?.username, password: credentials?.password,
            useHTTPS: info.useHTTPS
        )
    }

    static func attemptONVIFResolve(params: ONVIFResolveParams) async throws -> String? {
        let client = makeONVIFClient(for: params.info, credentials: params.credentials)
        do {
            return try await client.getStreamURI(profileToken: params.token)
        } catch {
            try Task.checkCancellation()
            Log.rtsp.warning("ONVIF fetch failed for '\(params.sourceName)': \(error)")
        }

        guard let uuid = params.info.deviceUUID, !uuid.isEmpty else { return nil }

        Log.rtsp.info("Scanning for device \(uuid) via WS-Discovery")
        let devices = await ONVIFDiscovery().scan()
        try Task.checkCancellation()

        guard let match = devices.first(where: { $0.id == uuid }) else { return nil }
        Log.rtsp.info("Found device at \(match.host):\(match.port)")

        var updated = params.info
        updated.host = match.host
        updated.port = match.port
        updated.useHTTPS = match.useHTTPS
        await MainActor.run { [updated] in
            guard let sourceManager = params.sourceManager else { return }
            sourceManager.updateSource(
                id: params.sourceID, name: params.sourceName,
                sourceType: .onvif(updated), credentials: params.credentials
            )
        }

        let newClient = makeONVIFClient(for: updated, credentials: params.credentials)
        do {
            return try await newClient.getStreamURI(profileToken: params.token)
        } catch {
            try Task.checkCancellation()
            Log.rtsp.error("ONVIF fetch failed at new address: \(error)")
        }

        return nil
    }
}

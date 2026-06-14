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

    static func attemptONVIFResolve(params: ONVIFResolveParams) async throws -> String? {
        let client = ONVIFClient(
            host: params.info.host, port: params.info.port,
            username: params.credentials?.username,
            password: params.credentials?.password
        )

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

        await MainActor.run {
            guard let sourceManager = params.sourceManager else { return }
            var updated = params.info
            updated.host = match.host
            updated.port = match.port
            sourceManager.updateSource(
                id: params.sourceID, name: params.sourceName,
                sourceType: .onvif(updated), credentials: params.credentials
            )
        }

        let newClient = ONVIFClient(
            host: match.host, port: match.port,
            username: params.credentials?.username,
            password: params.credentials?.password
        )
        do {
            return try await newClient.getStreamURI(profileToken: params.token)
        } catch {
            try Task.checkCancellation()
            Log.rtsp.error("ONVIF fetch failed at new address: \(error)")
        }

        return nil
    }
}

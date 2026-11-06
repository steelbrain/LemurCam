import Foundation
import IPCamKit

@MainActor
internal final class BootSanityChecker {
    private let sourceManager: SourceManager
    private var task: Task<Void, Never>?

    init(sourceManager: SourceManager) {
        self.sourceManager = sourceManager
    }

    func run() {
        let activeID = sourceManager.activeSourceID
        let sources = sourceManager.sources.filter { $0.id != activeID }

        guard !sources.isEmpty else { return }

        // Mark non-active sources as pending
        for source in sources {
            sourceManager.updateConnectionStatus(for: source.id, status: .pending)
        }

        task = Task {
            await withTaskGroup(of: Void.self) { group in
                for source in sources {
                    let credentials = self.sourceManager.credentials(for: source.id)
                    group.addTask {
                        let reachable = await Self.probe(source: source, credentials: credentials)
                        await MainActor.run {
                            self.recordProbeResult(reachable: reachable, for: source.id)
                        }
                    }
                }
            }
            Log.app.info("Boot sanity check complete")
        }
    }

    /// Shows a probe's result in the source list. A probe can finish many seconds after
    /// launch; by then the user may have made that camera the active one, whose status
    /// belongs to the live stream, or deleted it. In both cases the result is dropped.
    func recordProbeResult(reachable: Bool, for sourceID: UUID) {
        guard sourceID != sourceManager.activeSourceID,
              sourceManager.sources.contains(where: { $0.id == sourceID }) else { return }
        sourceManager.updateConnectionStatus(for: sourceID, status: reachable ? .connected : .error)
        sourceManager.updateErrorMessage(for: sourceID, message: reachable ? nil : "Unreachable")
    }

    private static func probe(source: CameraSource, credentials: SourceCredentials?) async -> Bool {
        switch source.sourceType {
        case .onvif(let info):
            return await probeONVIF(info: info, credentials: credentials)
        case .rtsp(let info):
            return await probeRTSP(info: info, credentials: credentials)
        }
    }

    private static func probeONVIF(
        info: ONVIFSourceInfo, credentials: SourceCredentials?
    ) async -> Bool {
        let client = ONVIFClient(
            host: info.host, port: info.port,
            username: credentials?.username,
            password: credentials?.password,
            useHTTPS: info.useHTTPS
        )
        do {
            _ = try await ONVIFTimeout.run(seconds: ONVIFTimeout.launchProbe) {
                try await client.getProfiles()
            }
            return true
        } catch {
            return false
        }
    }

    private static func probeRTSP(
        info: RTSPSourceInfo, credentials: SourceCredentials?
    ) async -> Bool {
        let rtspCredentials: Credentials? = credentials.map {
            Credentials(username: $0.username, password: $0.password)
        }
        let session = RTSPClientSession(url: info.url, credentials: rtspCredentials)
        do {
            _ = try await withThrowingTaskGroup(
                of: SessionDescription.self
            ) { group -> SessionDescription in
                group.addTask {
                    try await session.start()
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: Tuning.streamStallTimeoutNs)
                    throw CancellationError()
                }
                guard let result = try await group.next() else {
                    throw CancellationError()
                }
                group.cancelAll()
                return result
            }
            await session.stop()
            return true
        } catch {
            await session.stop()
            return false
        }
    }
}

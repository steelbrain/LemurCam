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
                            if reachable {
                                self.sourceManager.updateConnectionStatus(
                                    for: source.id, status: .connected
                                )
                                self.sourceManager.updateErrorMessage(for: source.id, message: nil)
                            } else {
                                self.sourceManager.updateConnectionStatus(
                                    for: source.id, status: .error
                                )
                                self.sourceManager.updateErrorMessage(
                                    for: source.id, message: "Unreachable"
                                )
                            }
                        }
                    }
                }
            }
            Log.app.info("Boot sanity check complete")
        }
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
            password: credentials?.password
        )
        do {
            _ = try await client.getProfiles()
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

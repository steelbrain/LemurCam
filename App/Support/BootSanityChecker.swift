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
                        let failure = await Self.probe(source: source, credentials: credentials)
                        await MainActor.run {
                            self.recordProbeResult(failure: failure, for: source)
                        }
                    }
                }
            }
            Log.app.info("Boot sanity check complete")
        }
    }

    /// Shows a probe's result in the source list: `failure` says why `probed`, the
    /// camera as saved when its probe started, could not be used, and is nil when it
    /// answered. A probe can finish many seconds after launch; by then the user may
    /// have made that camera the active one, whose status belongs to the live stream,
    /// deleted it, or edited it. A result about the camera before an edit (a password
    /// fixed since, say) said "Authentication failed" until the next launch. Unless the
    /// camera is still saved as it was probed, the result is dropped.
    func recordProbeResult(failure: String?, for probed: CameraSource) {
        guard probed.id != sourceManager.activeSourceID,
              sourceManager.sources.first(where: { $0.id == probed.id }) == probed else { return }
        sourceManager.updateConnectionStatus(for: probed.id, status: failure == nil ? .connected : .error)
        sourceManager.updateErrorMessage(for: probed.id, message: failure)
    }

    /// What to show for a camera the probe could not use, such as "Authentication
    /// failed", rather than calling every failure unreachable. ONVIF errors describe
    /// the camera's answer without its address or credentials, and IPCamKit redacts
    /// credentials from the URLs in its messages. A probe that ran out of time says so.
    static func probeFailureMessage(for error: any Error) -> String {
        if error is RTSPStreamPipeline.TimeoutError {
            return ONVIFError.timedOut.localizedDescription
        }
        guard let described = (error as? LocalizedError)?.errorDescription, !described.isEmpty else {
            return "Unreachable"
        }
        return described
    }

    /// Nil when the camera answered; otherwise the message for the source list.
    private static func probe(source: CameraSource, credentials: SourceCredentials?) async -> String? {
        do {
            switch source.sourceType {
            case .onvif(let info):
                try await probeONVIF(info: info, credentials: credentials)
            case .rtsp(let info):
                try await probeRTSP(info: info, credentials: credentials)
            }
            return nil
        } catch {
            return probeFailureMessage(for: error)
        }
    }

    private static func probeONVIF(
        info: ONVIFSourceInfo, credentials: SourceCredentials?
    ) async throws {
        let client = StreamCoordinator.makeONVIFClient(for: info, credentials: credentials)
        _ = try await ONVIFTimeout.run(seconds: ONVIFTimeout.launchProbe) {
            try await client.getProfiles()
        }
    }

    private static func probeRTSP(
        info: RTSPSourceInfo, credentials: SourceCredentials?
    ) async throws {
        let rtspCredentials: Credentials? = credentials.map {
            Credentials(username: $0.username, password: $0.password)
        }
        let session = RTSPClientSession(url: info.url, credentials: rtspCredentials)
        try await probeRTSPStart(
            timeoutNs: Tuning.streamStallTimeoutNs,
            start: { _ = try await session.start() },
            stop: { await session.stop() }
        )
    }

    /// Runs `start` within `timeoutNs`, then `stop`. IPCamKit's `start()` ignores task
    /// cancellation, so cancelling it at the timeout left the probe waiting for as long
    /// as `start()` took. As in the stream pipeline, the timeout calls `stop`, which
    /// makes a running `start()` throw at once, and the probe fails with
    /// `RTSPStreamPipeline.TimeoutError`.
    nonisolated static func probeRTSPStart(
        timeoutNs: UInt64,
        start: @escaping @Sendable () async throws -> Void,
        stop: @escaping @Sendable () async -> Void
    ) async throws {
        do {
            try await RTSPStreamPipeline.withConnectTimeout(nanoseconds: timeoutNs, start: start, abort: stop)
        } catch {
            await stop()
            throw error
        }
        await stop()
    }
}

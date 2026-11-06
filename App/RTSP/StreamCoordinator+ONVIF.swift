import Foundation
import os

/// What resolving an ONVIF camera's stream URI produced: the URI, or why there is none.
/// The failure's error is shown when there is no stored URI to try, or the failure
/// rules it out (`ONVIFResolveFailure.allowsStoredURI`).
internal typealias ONVIFStreamURIResult = Result<ResolvedONVIFStreamURI, ONVIFResolveFailure>

/// Why an ONVIF camera's stream URI could not be resolved.
internal struct ONVIFResolveFailure: Error {
    /// What the camera answered, or that nothing answered: at the saved address, or at
    /// the address the scan found the camera at when it was asked there.
    let error: any Error
    /// The scan found the camera at another address, and asking it there failed.
    let cameraMoved: Bool

    init(_ error: any Error, cameraMoved: Bool = false) {
        self.error = error
        self.cameraMoved = cameraMoved
    }

    /// Whether the stream URI stored with the camera may be connected to instead. Not
    /// once the camera was found at another address: the stored URI names the address
    /// it left, where another device may answer now. The error from the new address
    /// hid the one from the saved address, so after a refused login there the saved
    /// credentials went to the stored URI's host. Otherwise as
    /// `StreamCoordinator.mayFallBackToStoredURI(after:)` decides.
    var allowsStoredURI: Bool {
        !cameraMoved && StreamCoordinator.mayFallBackToStoredURI(after: error)
    }
}

/// A stream URI an ONVIF camera reported, and the host of the ONVIF service that
/// reported it: the saved one, or the one rediscovery found the camera at.
internal struct ResolvedONVIFStreamURI: Equatable, Sendable {
    let uri: String
    let onvifHost: String
}

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

/// Whether a resolve found its camera at another address, shared by the resolve and
/// the task that ends it at its overall time limit. That failure must rule out the
/// stored stream URI too (`ONVIFResolveFailure.cameraMoved`): it names the address the
/// camera left, and the deadline can pass while the camera is asked where it was found.
internal final class ONVIFResolveProgress: Sendable {
    private let moveFound = OSAllocatedUnfairLock(initialState: false)

    var cameraMoved: Bool { moveFound.withLock { $0 } }

    func recordMove() {
        moveFound.withLock { $0 = true }
    }

    /// `error` as the resolve's failure: a camera found elsewhere once the scan found it.
    func failure(_ error: any Error) -> ONVIFResolveFailure {
        ONVIFResolveFailure(error, cameraMoved: cameraMoved)
    }
}

extension StreamCoordinator {
    /// Resolves the stream URI within `timeout`; running out of time is reported as
    /// `ONVIFError.timedOut`, as a camera found elsewhere when the scan had found it.
    static func resolveONVIFStreamURI(
        params: ONVIFResolveParams,
        timeout: TimeInterval = Tuning.onvifReconnectTimeout
    ) async -> ONVIFStreamURIResult {
        let progress = ONVIFResolveProgress()
        do {
            return try await withThrowingTaskGroup(of: ONVIFStreamURIResult.self) { group in
                group.addTask { try await Self.attemptONVIFResolve(params: params, progress: progress) }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    Log.rtsp.warning("ONVIF reconnect timed out after \(timeout)s")
                    return .failure(progress.failure(ONVIFError.timedOut))
                }
                let result = try await group.next() ?? .failure(progress.failure(ONVIFError.timedOut))
                group.cancelAll()
                return result
            }
        } catch {
            return .failure(progress.failure(error))
        }
    }

    /// What to connect to for a stream URI the camera at `onvifHost` just reported.
    /// IPCamKit refuses a URI whose login has a raw `#` or `?` (its
    /// `checkAmbiguousUserInfo`), so such a camera could never stream. That URI is
    /// split at its last `@`, as saved URLs are (`SourceCredentials.extractingFromRTSPURL`),
    /// and connected to without its login, which is used only when the source has no
    /// saved credentials. `URLComponents` fails on some of these
    /// (`rtsp://user:p#ss@192.0.2.5/stream`) and reads others as an address: host
    /// `user` and port 1234 in `user:1234#ab@`, an empty port in `user:#ab@`, host `us`
    /// in `us#er:pw@`. A URI is split as `SourceCredentials.splitsAtLastAt` says, the
    /// rule the saved fallback URI follows too: when no `/` or `?` comes before the
    /// last `@`, or else only when what follows it is `onvifHost`, since that `@` may
    /// belong to a query (`?password=p@ss`), and the saved login must never go to a
    /// host taken from a query. That holds for a URI `URLComponents` can't read as
    /// well: split at the `@` in `?password=p@ss word`, the rest of the password,
    /// `ss word`, was taken for the host. A URI that is not split loses the userinfo
    /// `URLComponents` reads, as the saved copy does: connected to as reported, a space
    /// in that login (`rtsp://admin:pa ss@cam/s`) or an `@` in the query after it
    /// (`?a=b@c`) made IPCamKit refuse every connect, even with saved credentials to
    /// use instead. So did any `@` after the host of a URI with a port
    /// (`rtsp://192.0.2.5:554/live?password=Adm1n@2024`); one in a URI whose host is
    /// `onvifHost` or an IP address is written `%40`. Both go by
    /// `SourceCredentials.extractingLogin(fromReportedURI:onvifHost:)`, which decides
    /// the saved copy too. A URI it can't take a login out of is connected to as
    /// reported, with the saved credentials.
    nonisolated static func connectionTarget(
        forResolvedURI uri: String, reportedBy onvifHost: String, savedCredentials: SourceCredentials?
    ) -> (url: String, credentials: SourceCredentials?) {
        let reported = SourceCredentials.extractingLogin(fromReportedURI: uri, onvifHost: onvifHost)
        guard let url = reported.url else { return (uri, savedCredentials) }
        return (url, savedCredentials ?? reported.credentials)
    }

    /// Whether a camera whose stream URI could not be resolved at its saved address may
    /// still be connected to at its stored stream URI (one found at another address
    /// never is; see `ONVIFResolveFailure.allowsStoredURI`). When nothing answered, or
    /// what answered was not a working ONVIF service, the stored URI is how a camera
    /// with a broken ONVIF service but working RTSP still streams. A refused login or a
    /// SOAP fault is an ONVIF device's answer, and not necessarily this camera's: after
    /// two cameras swap addresses the stored URI's address belongs to the other one,
    /// and connecting there sent it an RTSP login on every retry. When it is this
    /// camera refusing the login, the RTSP connect would send the same credentials again.
    nonisolated static func mayFallBackToStoredURI(after error: any Error) -> Bool {
        guard let onvifError = error as? ONVIFError else { return true }
        switch onvifError {
        case .authenticationFailed, .soapFault:
            return false
        case .invalidURL, .networkError, .httpStatus, .parseError, .timedOut:
            return true
        }
    }

    /// The message shown for a camera whose stream URI could not be resolved. ONVIF
    /// errors describe what the camera answered (or that it did not answer); they never
    /// contain a URL or credentials.
    nonisolated static func onvifResolveFailureMessage(for error: any Error) -> String {
        guard let described = (error as? LocalizedError)?.errorDescription, !described.isEmpty else {
            return "Could not reach camera"
        }
        return described
    }

    nonisolated static func makeONVIFClient(for info: ONVIFSourceInfo, credentials: SourceCredentials?) -> ONVIFClient {
        ONVIFClient(
            host: info.host, port: info.port,
            username: credentials?.username, password: credentials?.password,
            useHTTPS: info.useHTTPS
        )
    }

    /// Asks the camera for the stream URI at its saved address. Only when the address
    /// gives no answer, or an answer that may not be this camera's ONVIF service (see
    /// `ONVIFRediscovery.shouldRediscover`), does it look for the camera with
    /// WS-Discovery, and it asks again only where the scan finds the camera moved to.
    /// An address the scan reports is saved only when it differs from the saved one and
    /// `ONVIFRediscovery.shouldSave` allows it (after a rejected login or a SOAP fault,
    /// only once the camera answered there); otherwise it is used for this connection
    /// only. A failure carries the error from
    /// the saved address, unless the camera was found elsewhere and failed there, which
    /// the failure records (`ONVIFResolveFailure.cameraMoved`), as `progress` does as
    /// soon as the scan found it there. Throws only when cancelled.
    static func attemptONVIFResolve(
        params: ONVIFResolveParams, progress: ONVIFResolveProgress = ONVIFResolveProgress()
    ) async throws -> ONVIFStreamURIResult {
        let savedAddressError: any Error
        do {
            return .success(try await fetchStreamURI(from: params.info, params: params))
        } catch {
            try Task.checkCancellation()
            Log.rtsp.warning("ONVIF fetch failed for '\(params.sourceName)': \(error.localizedDescription)")
            guard ONVIFRediscovery.shouldRediscover(after: error, at: params.info) else {
                return .failure(ONVIFResolveFailure(error))
            }
            savedAddressError = error
        }

        guard let uuid = params.info.deviceUUID, !uuid.isEmpty else {
            return .failure(ONVIFResolveFailure(savedAddressError))
        }

        Log.rtsp.info("Scanning for device \(uuid) via WS-Discovery")
        let devices = await params.environment.scan()
        try Task.checkCancellation()

        switch ONVIFRediscovery.outcome(for: params.info, among: devices) {
        case .notFound:
            Log.rtsp.info("Device \(uuid) did not answer the scan")
        case .ambiguous:
            Log.rtsp.warning("Several addresses claim device \(uuid); keeping the saved address")
        case .unchanged:
            Log.rtsp.info("Device \(uuid) still answers at the saved address")
        case .moved(let moved):
            Log.rtsp.info("Found device at \(moved.host):\(moved.port)")
            progress.recordMove()
            return try await connect(movedTo: moved, after: savedAddressError, params: params)
        }
        return .failure(ONVIFResolveFailure(savedAddressError))
    }

    /// GetStreamUri from the camera at `info`'s address, within
    /// `Tuning.onvifReconnectFetchTimeout`. Each fetch has its own limit so that the
    /// overall budget (`Tuning.onvifReconnectTimeout`) always leaves room for the scan
    /// and the fetch from the address it finds.
    private static func fetchStreamURI(
        from info: ONVIFSourceInfo, params: ONVIFResolveParams
    ) async throws -> ResolvedONVIFStreamURI {
        let client = params.environment.makeClient(info, params.credentials)
        let token = params.token
        let uri = try await ONVIFTimeout.run(seconds: Tuning.onvifReconnectFetchTimeout) {
            try await client.getStreamURI(profileToken: token)
        }
        return ResolvedONVIFStreamURI(uri: uri, onvifHost: info.host)
    }

    /// Asks the camera at the address the scan found. A move `ONVIFRediscovery.shouldSave`
    /// allows is saved before asking, or, after a rejected login or a SOAP fault at the
    /// saved address, only once the camera answered there
    /// (`ONVIFRediscovery.savesMoveOnlyOnceAnswered`).
    private static func connect(
        movedTo moved: ONVIFSourceInfo, after savedAddressError: any Error, params: ONVIFResolveParams
    ) async throws -> ONVIFStreamURIResult {
        let save = ONVIFRediscovery.shouldSave(moved, replacing: params.info)
        let saveOnceAnswered = ONVIFRediscovery.savesMoveOnlyOnceAnswered(after: savedAddressError)
        if !save {
            Log.rtsp.info("Using the address found for '\(params.sourceName)' for this connection only")
        } else if !saveOnceAnswered {
            await saveMove(moved, params: params)
        }
        do {
            let resolved = try await fetchStreamURI(from: moved, params: params)
            if save, saveOnceAnswered {
                try Task.checkCancellation()
                await saveMove(moved, params: params)
            }
            return .success(resolved)
        } catch {
            try Task.checkCancellation()
            Log.rtsp.error("ONVIF fetch failed at new address: \(error.localizedDescription)")
            if save, saveOnceAnswered {
                Log.rtsp.info("Keeping the saved address for '\(params.sourceName)': the camera found did not answer")
            }
            return .failure(ONVIFResolveFailure(error, cameraMoved: true))
        }
    }

    /// Saved only while the resolve is current and the camera is still saved at the
    /// address the resolve started from (`SourceManager.updateONVIFAddress`). Both are
    /// checked on the main actor, where an edit that cancels the resolve runs: checked
    /// before the hop, an edit could land in between and the move overwrite it.
    private static func saveMove(_ moved: ONVIFSourceInfo, params: ONVIFResolveParams) async {
        await MainActor.run {
            guard !Task.isCancelled else { return }
            params.sourceManager?.updateONVIFAddress(id: params.sourceID, from: params.info, to: moved)
        }
    }
}

import Foundation
import os
import ServiceManagement

/// The privileged-helper calls `SetupCoordinator` makes: `AudioDeviceInstaller` in
/// the app, a fake in tests (so a helper that answers late, fails, or never answers
/// can be exercised without XPC).
internal protocol AudioHelperClient: AnyObject {
    var state: AudioDeviceInstaller.State { get }
    var bundledDriverVersion: String? { get }
    func registerHelper() throws
    func openLoginItemsSettings()
    func installDriver(completion: @escaping (MicrophoneOperationResult) -> Void)
    func uninstallDriver(completion: @escaping (MicrophoneOperationResult) -> Void)
    func installedDriver(completion: @escaping (InstalledDriverCheck) -> Void)
}

/// App-side control of the privileged helper: registers the SMAppService daemon,
/// reports its approval state, and drives install/uninstall/version queries over
/// a code-signing-pinned XPC connection. Each request uses a short-lived
/// connection kept alive by the reply closure until the reply (or error) fires.
internal final class AudioDeviceInstaller: AudioHelperClient {
    /// Registration state of the helper daemon, mapped from `SMAppService.Status`.
    enum State {
        case notRegistered
        case requiresApproval
        case enabled
        case notFound
    }

    private static let log = Logger(subsystem: "cam.lemur.app", category: "audio-installer")
    private let service = SMAppService.daemon(plistName: LemurAudioHelper.daemonPlistName)

    /// Longest a check waits for `helperBuild` once `installedVersion` answered. A
    /// current helper answers at once; one from v1.5 or before never does.
    static let helperBuildTimeLimit: TimeInterval = 2

    var state: State {
        switch service.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .notRegistered
        case .notFound: return .notFound
        @unknown default: return .notFound
        }
    }

    /// CFBundleVersion of the `.driver` bundled inside this app — the version that
    /// would be installed. Compared against the installed driver's version to
    /// detect a stale install after an app update. nil if the bundle is missing.
    var bundledDriverVersion: String? {
        guard let path = bundledDriverPath else { return nil }
        let infoPath = (path as NSString).appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOfFile: infoPath),
              let version = info["CFBundleVersion"] as? String else { return nil }
        return version
    }

    /// Register the helper daemon. After this the user must approve it in
    /// System Settings > General > Login Items (state becomes `requiresApproval`).
    func registerHelper() throws {
        try service.register()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Ask the helper to install the driver bundled inside this app.
    func installDriver(completion: @escaping (MicrophoneOperationResult) -> Void) {
        guard let driverPath = bundledDriverPath else {
            completion(.failed("Bundled driver not found in app bundle"))
            return
        }
        withHelper(onUnavailable: { completion(.noAnswer($0)) }, body: { helper, connection in
            helper.installDriver(fromPath: driverPath) { success, message in
                completion(MicrophoneOperationResult(success: success, message: message))
                connection.invalidate()
            }
        })
    }

    func uninstallDriver(completion: @escaping (MicrophoneOperationResult) -> Void) {
        withHelper(onUnavailable: { completion(.noAnswer($0)) }, body: { helper, connection in
            helper.uninstallDriver { success, message in
                completion(MicrophoneOperationResult(success: success, message: message))
                connection.invalidate()
            }
        })
    }

    /// Reports the installed driver: its CFBundleVersion from the helper, and whether
    /// the installed copy is sealed to root, checked here. `reachable` is false when
    /// the privileged helper couldn't be reached (a transient condition) — distinct
    /// from a reachable helper reporting no installed driver (`reachable == true,
    /// version == nil`), so callers don't mistake a hiccup for "not installed".
    ///
    /// The seal is checked by the app, not asked of the helper: a helper from an
    /// older version can still be the one serving requests (see `HelperIdleExit`),
    /// and the copies those helpers installed are user-owned. The HAL plug-ins
    /// directory is readable by every user, so this needs no privileges. Which helper
    /// answered is told by `helperBuild` (see `checkInstalledDriver`).
    func installedDriver(completion: @escaping (InstalledDriverCheck) -> Void) {
        Self.checkInstalledDriver(
            on: makeConnection(), identifyWithin: Self.helperBuildTimeLimit,
            sealed: { Self.installedCopy.installedCopyIsSealed() }, completion: completion
        )
    }

    /// The installed-driver check over `connection`, which it resumes and invalidates
    /// once done: `installedVersion`, then `helperBuild`. That is sent only once the
    /// version came back, since NSXPC in a helper from v1.5 or before, whose exported
    /// interface lacks the selector, drops the message and ends the connection, and
    /// would take an `installedVersion` still waiting with it. `completion` runs once:
    /// unreachable when the connection ends before the version came back; otherwise
    /// with the helper current when it answered `helperBuild`, and stale when the
    /// connection ended or `limit` passed first. Internal so the tests can run it
    /// against an in-process listener.
    static func checkInstalledDriver(
        on connection: NSXPCConnection, identifyWithin limit: TimeInterval,
        sealed: @escaping @Sendable () -> Bool, completion: @escaping (InstalledDriverCheck) -> Void
    ) {
        let request = DriverCheckRequest(connection: connection, completion: completion)
        withHelper(on: connection, onUnavailable: { _ in request.connectionEnded() }, body: { helper, _ in
            helper.installedVersion { version in
                request.versionAnswered(
                    InstalledDriverCheck(reachable: true, version: version, sealed: version != nil && sealed())
                )
                helper.helperBuild { build in request.identified(byBuild: build) }
                DispatchQueue.global().asyncAfter(deadline: .now() + limit) { request.identified(byBuild: nil) }
            }
        })
    }

    // MARK: - Private

    /// The installed location, for the read-only seal check; this side never
    /// installs, so its signature check refuses everything.
    private static var installedCopy: DriverInstaller {
        DriverInstaller(
            pluginsDirectory: LemurAudioHelper.halPluginsDirectory,
            bundleName: LemurAudioHelper.driverBundleName,
            owner: .root,
            validateSignature: { _ in "the app does not install the driver itself" }
        )
    }

    /// The same location the helper derives from this app's code signature; the
    /// helper ignores the path it is sent, which is kept for older helpers.
    private var bundledDriverPath: String? {
        let path = LemurAudioHelper.bundledDriverPath(inAppBundle: Bundle.main.bundlePath)
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// Opens a pinned XPC connection and vends the helper proxy. `body` owns the
    /// connection and must `invalidate()` it once its reply fires.
    private func withHelper(onUnavailable: @escaping (String) -> Void,
                            body: (LemurAudioHelperProtocol, NSXPCConnection) -> Void) {
        Self.withHelper(on: makeConnection(), onUnavailable: onUnavailable, body: body)
    }

    /// A connection to the privileged helper, pinned to its code signature.
    private func makeConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(machServiceName: LemurAudioHelper.machServiceName, options: .privileged)
        connection.setCodeSigningRequirement(LemurAudioHelper.helperRequirement)
        return connection
    }

    /// Resumes `connection` and vends the helper proxy. `body` owns the connection
    /// and must `invalidate()` it once its reply fires.
    private static func withHelper(on connection: NSXPCConnection, onUnavailable: @escaping (String) -> Void,
                                   body: (LemurAudioHelperProtocol, NSXPCConnection) -> Void) {
        connection.remoteObjectInterface = NSXPCInterface(with: LemurAudioHelperProtocol.self)
        connection.invalidationHandler = {
            log.debug("helper connection invalidated")
        }
        connection.resume()
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            onUnavailable("Helper unavailable: \(error.localizedDescription)")
            connection.invalidate()
        }
        guard let helper = proxy as? LemurAudioHelperProtocol else {
            onUnavailable("Could not obtain helper proxy")
            connection.invalidate()
            return
        }
        body(helper, connection)
    }
}

/// One installed-driver check in flight. XPC replies, the connection's end and the
/// `helperBuild` time limit report to it from any thread; it completes exactly once,
/// then invalidates the check's connection.
private final class DriverCheckRequest: Sendable {
    private struct State {
        var connection: NSXPCConnection?
        var completion: ((InstalledDriverCheck) -> Void)?
        /// What `installedVersion` answered, before the helper is identified.
        var answered: InstalledDriverCheck?
    }

    private let state: OSAllocatedUnfairLock<State>

    init(connection: NSXPCConnection, completion: @escaping (InstalledDriverCheck) -> Void) {
        state = OSAllocatedUnfairLock(uncheckedState: State(connection: connection, completion: completion))
    }

    func versionAnswered(_ check: InstalledDriverCheck) {
        state.withLockUnchecked { $0.answered = check }
    }

    /// `helperBuild` answered `build`, or nil: its time limit passed first.
    func identified(byBuild build: String?) {
        finish { answered in
            guard var check = answered else { return nil }
            check.helper = AudioHelperIdentity(helperBuild: build)
            return check
        }
    }

    /// The connection failed or ended: before `installedVersion` answered, the helper
    /// could not be reached; after it, it did not answer `helperBuild`.
    func connectionEnded() {
        finish { answered in
            guard var check = answered else { return .unreachable }
            check.helper = AudioHelperIdentity(helperBuild: nil)
            return check
        }
    }

    /// Completes with what `result` makes of the version answered, unless it already
    /// completed or `result` gives nothing yet.
    private func finish(_ result: (InstalledDriverCheck?) -> InstalledDriverCheck?) {
        typealias Ending = (completion: (InstalledDriverCheck) -> Void, check: InstalledDriverCheck,
                            connection: NSXPCConnection?)
        let ending = state.withLockUnchecked { state -> Ending? in
            guard let completion = state.completion, let check = result(state.answered) else { return nil }
            defer {
                state.completion = nil
                state.connection = nil
            }
            return (completion, check, state.connection)
        }
        guard let ending else { return }
        ending.completion(ending.check)
        ending.connection?.invalidate()
    }
}

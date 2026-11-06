import Foundation
import OSLog
import ServiceManagement

/// App-side control of the privileged helper: registers the SMAppService daemon,
/// reports its approval state, and drives install/uninstall/version queries over
/// a code-signing-pinned XPC connection. Each request uses a short-lived
/// connection kept alive by the reply closure until the reply (or error) fires.
internal final class AudioDeviceInstaller {
    /// Registration state of the helper daemon, mapped from `SMAppService.Status`.
    enum State {
        case notRegistered
        case requiresApproval
        case enabled
        case notFound
    }

    private let log = Logger(subsystem: "cam.lemur.app", category: "audio-installer")
    private let service = SMAppService.daemon(plistName: LemurAudioHelper.daemonPlistName)

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

    func unregisterHelper() throws {
        try service.unregister()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Ask the helper to install the driver bundled inside this app.
    func installDriver(completion: @escaping (Bool, String) -> Void) {
        guard let driverPath = bundledDriverPath else {
            completion(false, "Bundled driver not found in app bundle")
            return
        }
        withHelper(onUnavailable: { completion(false, $0) }, body: { helper, connection in
            helper.installDriver(fromPath: driverPath) { success, message in
                completion(success, message)
                connection.invalidate()
            }
        })
    }

    func uninstallDriver(completion: @escaping (Bool, String) -> Void) {
        withHelper(onUnavailable: { completion(false, $0) }, body: { helper, connection in
            helper.uninstallDriver { success, message in
                completion(success, message)
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
    /// directory is readable by every user, so this needs no privileges.
    func installedDriver(completion: @escaping (InstalledDriverCheck) -> Void) {
        withHelper(onUnavailable: { _ in completion(.unreachable) }, body: { helper, connection in
            helper.installedVersion { version in
                let sealed = version != nil && Self.installedCopy.installedCopyIsSealed()
                completion(InstalledDriverCheck(reachable: true, version: version, sealed: sealed))
                connection.invalidate()
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
        let connection = NSXPCConnection(machServiceName: LemurAudioHelper.machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: LemurAudioHelperProtocol.self)
        connection.setCodeSigningRequirement(LemurAudioHelper.helperRequirement)
        connection.invalidationHandler = { [weak self] in
            self?.log.debug("helper connection invalidated")
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

import Foundation

/// Persists the "we asked the user to relaunch for bundle version X" marker that
/// drives the stuck-app-restart → reboot escalation in `CameraExtensionController`.
///
/// It snapshots the *previous* launch's value at init, so writes made during this
/// launch don't pollute the "did the restart already happen?" decision. Injectable
/// over `UserDefaults` so the escalation round-trip is unit-testable without
/// SystemExtensions — mirrors `SetupStateStore`.
internal struct CameraRestartMarker {
    private let defaults: UserDefaults
    private static let key = "LemurCam.cameraRestartRequestedVersion"

    /// The bundled version we last asked the user to relaunch for, captured at init
    /// (i.e. reflecting a prior launch, not anything recorded this launch).
    let previousRequestedVersion: String?

    init(defaults: UserDefaults) {
        self.defaults = defaults
        self.previousRequestedVersion = defaults.string(forKey: Self.key)
    }

    /// Whether we already asked for an app restart for this exact bundle version in
    /// a prior launch. If so and the running version is *still* stale, the restart
    /// didn't take the update → escalate to a reboot.
    func wasRestartAlreadyTried(forBundled bundled: String?) -> Bool {
        guard let bundled, let previousRequestedVersion else { return false }
        return previousRequestedVersion == bundled
    }

    func record(version: String?) {
        guard let version else { return }
        defaults.set(version, forKey: Self.key)
    }

    func clear() {
        defaults.removeObject(forKey: Self.key)
    }
}

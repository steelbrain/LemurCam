// MARK: - Virtual Camera

extension StreamCoordinator {
    /// Run CMIO device discovery for the virtual camera. Called by the
    /// `SetupCoordinator` once the extension is installed and the device is live.
    func beginCameraDiscovery() {
        model.beginDiscovery()
    }

    /// Hand the virtual camera the Resolution and Frame Rate settings after the user
    /// changed them in Settings.
    func applyVirtualCameraFormat() {
        model.applyPreferredFormat()
    }
}

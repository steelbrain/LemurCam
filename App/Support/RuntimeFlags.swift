/// The virtual-camera format this run of the app started with. Resolution and
/// frame-rate changes take effect only after a restart, so Settings compares its
/// pickers against these values to decide whether to show the restart notice.
internal struct LaunchedStreamFormat: Equatable {
    let resolution: LemurCamConfig.Resolution
    let frameRate: LemurCamConfig.FrameRate

    /// Whether the chosen values differ from the ones running.
    func needsRestart(resolution: LemurCamConfig.Resolution, frameRate: LemurCamConfig.FrameRate) -> Bool {
        resolution != self.resolution || frameRate != self.frameRate
    }
}

@MainActor
internal enum RuntimeFlags {
    /// Captured by `applicationDidFinishLaunching`; nil before then and in the
    /// unit-test host, which does no launch work.
    private(set) static var launchedFormat: LaunchedStreamFormat?

    /// Record the stored format as the one this launch runs with. Only the first
    /// call counts.
    static func captureLaunchedFormat() {
        guard launchedFormat == nil else { return }
        launchedFormat = LaunchedStreamFormat(
            resolution: LemurCamConfig.storedResolution,
            frameRate: LemurCamConfig.storedFrameRate
        )
    }

    /// Whether the chosen values need a restart to apply. Takes the view's own
    /// state rather than re-reading defaults, so the notice updates with the pickers.
    static func needsRestart(resolution: LemurCamConfig.Resolution, frameRate: LemurCamConfig.FrameRate) -> Bool {
        launchedFormat?.needsRestart(resolution: resolution, frameRate: frameRate) ?? false
    }
}

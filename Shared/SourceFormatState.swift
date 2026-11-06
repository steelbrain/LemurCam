/// The camera extension's format bookkeeping for `ExtensionDeviceRuntime`: the
/// format the source stream runs in, and the user's default, which the app sets
/// through the sink stream's standard CMIO format and frame-rate properties.
///
/// Apps that use the camera choose their own resolution and frame rate on the
/// source stream, and get them at once. The default reaches the source only
/// while no app is using it: one set while the source has consumers waits until
/// the last of them stops, so the app never changes the format under a running
/// consumer. A format an app chose stays until something changes it.
///
/// Pure and CMIO-free, so it is unit-tested through the app module; the runtime
/// keeps it under the same lock as the consumer count it is decided against.
internal struct SourceFormatState: Equatable, Sendable {
    /// The format the source stream runs in: what consuming apps get.
    private(set) var active: StreamFormatSelection
    /// The default the app last set on the sink stream, which the sink reports.
    private(set) var preferred: StreamFormatSelection
    /// A default set while the source had consumers, waiting for it to go idle.
    private(set) var pending: StreamFormatSelection?

    init(initial: StreamFormatSelection) {
        active = initial
        preferred = initial
    }

    /// A consuming app set the source stream's resolution, frame rate, or both
    /// (nil leaves one as it is). They apply at once. Returns whether the active
    /// format changed.
    @discardableResult
    mutating func sourceClientSet(
        resolution: LemurCamConfig.Resolution?, frameRate: LemurCamConfig.FrameRate?
    ) -> Bool {
        let previous = active
        if let resolution { active.resolution = resolution }
        if let frameRate { active.frameRate = frameRate }
        return active != previous
    }

    /// The app set the default resolution, frame rate, or both on the sink stream.
    /// With no consumers on the source, the default applies now: returns the new
    /// active format when that changed it, for the caller to announce. Otherwise it
    /// waits for `sourceBecameIdle` and this returns nil.
    mutating func defaultSet(
        resolution: LemurCamConfig.Resolution?,
        frameRate: LemurCamConfig.FrameRate?,
        sourceHasConsumers: Bool
    ) -> StreamFormatSelection? {
        if let resolution { preferred.resolution = resolution }
        if let frameRate { preferred.frameRate = frameRate }
        guard !sourceHasConsumers else {
            pending = preferred
            return nil
        }
        pending = nil
        return apply(preferred)
    }

    /// The source stream's last consumer stopped. A default that waited for this
    /// applies now: returns the new active format when it changed, for the caller
    /// to announce.
    mutating func sourceBecameIdle() -> StreamFormatSelection? {
        guard let waiting = pending else { return nil }
        pending = nil
        return apply(waiting)
    }

    private mutating func apply(_ format: StreamFormatSelection) -> StreamFormatSelection? {
        guard active != format else { return nil }
        active = format
        return format
    }
}

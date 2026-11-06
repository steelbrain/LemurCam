/// What the menu bar popover and the setup wizard's last step say when no camera is
/// listed. Pure, so it is testable without the views.
internal enum NoCameraNotice: Equatable {
    /// No camera is saved: offer to add one.
    case addCamera
    /// The saved cameras weren't loaded and saving is refused this session
    /// (`SourceStorage.SaveRefusal`): the empty list says nothing about what is saved,
    /// and adding a camera is refused until LemurCam restarts, so say why instead of
    /// offering to add one.
    case savedCamerasNotLoaded(SourceStorage.SaveRefusal)

    /// nil while any camera is listed.
    static func decide(sourceCount: Int, saveRefusal: SourceStorage.SaveRefusal?) -> Self? {
        guard sourceCount == 0 else { return nil }
        guard let saveRefusal else { return .addCamera }
        return .savedCamerasNotLoaded(saveRefusal)
    }

    /// Whether the wizard's last step offers Add Camera, which marks the step done and
    /// opens Settings → Cameras to add one there.
    var offersAddCamera: Bool { self == .addCamera }
}

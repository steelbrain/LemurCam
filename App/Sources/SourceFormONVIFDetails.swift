/// What the add/edit form read from an ONVIF camera, to be saved with it: the profiles
/// to pick from, the profile picked and its stream URL (the saved fallback), and the
/// device UUID and serial number that rediscovery tells the camera apart by. All of it
/// must come from the camera the form last connected to.
///
/// Adding a camera, connecting to one, then editing the URL and connecting to another
/// kept the first one's device UUID and serial number: the edit and the new Connect
/// cleared only the profiles and the stream URL, and a fetch keeps a device UUID it
/// already has (`ONVIFSourceInfo.resolvedDeviceUUID`). The second camera was saved
/// with the first one's identity, and a later rediscovery could re-point it to the
/// first camera's address. An edit of the URL and a new Connect now clear everything.
internal struct SourceFormONVIFDetails {
    private(set) var profiles: [ONVIFProfile] = []
    /// Bound to the Profile picker.
    var selectedProfileToken: String?
    private(set) var streamURI: String?
    private(set) var deviceUUID: String?
    private(set) var serialNumber: String?

    /// For a camera being added: nothing is read yet.
    init() {}

    /// A saved camera's details, as it was saved. Its profiles are fetched anew.
    init(saved: SourceFormONVIFAddressEdits.SavedDetails) {
        selectedProfileToken = saved.selectedProfileToken
        streamURI = saved.streamURI
        deviceUUID = saved.deviceUUID
        serialNumber = saved.serialNumber
    }

    /// The URL was edited, or Connect starts for a camera being added: nothing read
    /// from the camera before is kept, its device UUID and serial number included.
    mutating func clear() {
        self = Self()
    }

    /// The camera's profiles are fetched anew. Its device UUID and serial number stay:
    /// a saved camera keeps the ones it was saved with unless the camera reports its
    /// own (see `profilesFetched`).
    mutating func startFetchingProfiles() {
        profiles = []
        selectedProfileToken = nil
        streamURI = nil
    }

    /// The profiles and device information fetched from the camera.
    mutating func profilesFetched(_ fetched: ONVIFDeviceDetails) {
        profiles = fetched.profiles
        let serial = fetched.info?.serialNumber.flatMap { $0.isEmpty ? nil : $0 }
        if let serial { serialNumber = serial }
        deviceUUID = ONVIFSourceInfo.resolvedDeviceUUID(
            current: deviceUUID, serialNumber: serial, endpointReference: fetched.endpointReference
        )
    }

    /// A profile was picked and its stream URL is fetched. The one of the profile
    /// picked before is cleared, so it can't be saved as this one's: Add or Save before
    /// the fetch ends, or after it fails, saved the Sub profile with Main's URL.
    mutating func startFetchingStreamURI() {
        streamURI = nil
    }

    mutating func streamURIFetched(_ uri: String) {
        streamURI = uri
    }
}

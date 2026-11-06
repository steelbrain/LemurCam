/// What the add/edit form read from an ONVIF camera, to be saved with it: the profiles
/// to pick from, the profile picked and its stream URL (the saved fallback), and the
/// device UUID and serial number that rediscovery tells the camera apart by. All of it
/// must come from the camera the form last connected to. So must what the user decided
/// for the camera's address: the certificate trusted there (`CertificateTrustPrompt`),
/// and plain HTTP allowed there (`ONVIFPlainHTTPToggle`).
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
    private(set) var pinnedCertificate: CertificateFingerprint?
    /// Bound to the Allow Unencrypted HTTP checkbox.
    var allowsPlainHTTPOutsideLocalNetwork = false

    /// For a camera being added: nothing is read yet.
    init() {}

    /// A saved camera's details, as it was saved. Its profiles are fetched anew.
    init(saved: SourceFormONVIFAddressEdits.SavedDetails) {
        selectedProfileToken = saved.selectedProfileToken
        streamURI = saved.streamURI
        deviceUUID = saved.deviceUUID
        serialNumber = saved.serialNumber
        pinnedCertificate = saved.pinnedCertificate
        allowsPlainHTTPOutsideLocalNetwork = saved.allowsPlainHTTPOutsideLocalNetwork
    }

    /// What a client for the camera at the form's address may accept.
    var connectionPolicy: ONVIFConnectionPolicy {
        ONVIFConnectionPolicy(
            pinnedCertificate: pinnedCertificate, allowsPlainHTTPOutsideLocalNetwork: allowsPlainHTTPOutsideLocalNetwork
        )
    }

    /// The camera as the form saves it at `address`. Plain HTTP stays allowed only for
    /// an address that needs it: the checkbox is hidden for any other, and a choice
    /// left there must not apply to a later address.
    func sourceInfo(at address: SourceFormONVIFAddressEdits.Address) -> ONVIFSourceInfo {
        let needsAllowance = ONVIFLocalNetwork.needsPlainHTTPAllowance(host: address.host, useHTTPS: address.useHTTPS)
        return ONVIFSourceInfo(
            deviceUUID: deviceUUID, host: address.host, port: address.port,
            selectedProfileToken: selectedProfileToken, streamURI: streamURI,
            useHTTPS: address.useHTTPS, serialNumber: serialNumber, pinnedCertificate: pinnedCertificate,
            allowsPlainHTTPOutsideLocalNetwork: needsAllowance && allowsPlainHTTPOutsideLocalNetwork
        )
    }

    /// The URL was edited, or Connect starts for a camera being added: nothing read
    /// from the camera before is kept, its device UUID, serial number and trusted
    /// certificate included, and plain HTTP is no longer allowed. A Connect to the
    /// address already in the form (`keepingAddressDecisions`) keeps what the user
    /// decided for it: Connect again is how they retry after ticking the checkbox.
    mutating func clear(keepingAddressDecisions: Bool = false) {
        let kept = self
        self = Self()
        guard keepingAddressDecisions else { return }
        pinnedCertificate = kept.pinnedCertificate
        allowsPlainHTTPOutsideLocalNetwork = kept.allowsPlainHTTPOutsideLocalNetwork
    }

    /// The camera's profiles are fetched anew. Its device UUID and serial number stay:
    /// a saved camera keeps the ones it was saved with unless the camera reports its
    /// own (see `profilesFetched`). So does the certificate the user trusted.
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

    /// The user trusted the certificate with `fingerprint` for the camera.
    mutating func trust(_ fingerprint: CertificateFingerprint) {
        pinnedCertificate = fingerprint
    }
}

/// Ties the edit form's ONVIF details (the profile chosen, its stream URL, the device
/// UUID, the serial number, the trusted certificate and plain HTTP allowed) to the
/// address they were read from. Editing Host, Port
/// or Use HTTPS used to leave the old camera's details in place, and Save stored them
/// with the new address, so a later rediscovery looked for the old camera's UUID and
/// could move the source back to it. Moving the address away clears them; they come
/// back from a fetch at the new address, or as they were saved when the address is
/// put back. Save needs details that belong to the address in the fields.
internal struct SourceFormONVIFAddressEdits {
    struct Address: Equatable {
        let host: String
        let port: Int
        let useHTTPS: Bool
    }

    /// The details a saved camera was loaded with.
    struct SavedDetails: Equatable {
        let selectedProfileToken: String?
        let streamURI: String?
        let deviceUUID: String?
        let serialNumber: String?
        var pinnedCertificate: CertificateFingerprint?
        var allowsPlainHTTPOutsideLocalNetwork = false
    }

    /// What the form does with its details after an address edit.
    enum Change: Equatable {
        /// They belong to the address in the fields: leave them.
        case keep
        /// They were read from another address, or are cleared already: clear them
        /// all, along with the fetched profiles.
        case clear
        /// The address is the saved one again: show what was saved.
        case restore(SavedDetails)
    }

    private let savedAddress: Address?
    private let savedDetails: SavedDetails?
    /// The address the form's details belong to; nil when they belong to none.
    private var owner: Address?

    /// For a camera being added: there are no saved details.
    init() {
        savedAddress = nil
        savedDetails = nil
        owner = nil
    }

    /// For a saved camera, whose details belong to the address it was saved with.
    init(savedAt address: Address, details: SavedDetails) {
        savedAddress = address
        savedDetails = details
        owner = address
    }

    /// The details saved at `address`, when it is the saved camera's address.
    func savedDetails(at address: Address) -> SavedDetails? {
        address == savedAddress ? savedDetails : nil
    }

    /// The user edited the address to `address`.
    mutating func addressEdited(to address: Address) -> Change {
        guard address != owner else { return .keep }
        if address == savedAddress, let savedDetails {
            owner = address
            return .restore(savedDetails)
        }
        owner = nil
        return .clear
    }

    /// Profiles were fetched from `address`: the details now belong to it.
    mutating func fetchSucceeded(at address: Address) {
        owner = address
    }

    /// Whether details may be saved with `address`: they were read from it.
    func allowsSave(at address: Address) -> Bool {
        owner == address
    }
}

extension SourceFormONVIFAddressEdits.SavedDetails {
    /// The details of the camera saved as `info`.
    init(_ info: ONVIFSourceInfo) {
        self.init(
            selectedProfileToken: info.selectedProfileToken, streamURI: info.streamURI,
            deviceUUID: info.deviceUUID, serialNumber: info.serialNumber, pinnedCertificate: info.pinnedCertificate,
            allowsPlainHTTPOutsideLocalNetwork: info.allowsPlainHTTPOutsideLocalNetwork
        )
    }
}

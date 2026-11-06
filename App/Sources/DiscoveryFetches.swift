/// What the Discover Cameras sheet fetched from the camera picked in it: its profiles
/// and device information, then the stream URI of the profile picked. Each fetch
/// takes a ticket (`SourceFormFetchTickets`), and going Back, picking a camera or
/// picking another profile makes the earlier ones stale, so a stale fetch's reply (or
/// error) is dropped. Without them, a slow reply from the camera picked first
/// replaced the second one's profiles and device information (its manufacturer,
/// model and serial number were saved for the second), and the stream URI of the
/// profile picked first could be saved as the fallback of the one picked after it.
internal struct DiscoveryFetches {
    private(set) var profiles: [ONVIFProfile] = []
    private(set) var deviceInfo: ONVIFDeviceInfo?
    private(set) var streamURI: String?
    private(set) var isFetchingProfiles = false
    private(set) var error: String?
    private var tickets = SourceFormFetchTickets()

    /// Back, or another camera picked: what is in flight is dropped, and what was
    /// fetched is cleared.
    mutating func reset() {
        tickets.invalidate()
        profiles = []
        deviceInfo = nil
        streamURI = nil
        isFetchingProfiles = false
        error = nil
    }

    /// Connect: the picked camera's profiles and device information are fetched anew.
    /// Returns the fetch's ticket.
    mutating func startFetchingDetails() -> Int {
        reset()
        isFetchingProfiles = true
        return tickets.issue()
    }

    mutating func detailsFetched(_ details: ONVIFDeviceDetails, ticket: Int) {
        guard tickets.isCurrent(ticket) else { return }
        profiles = details.profiles
        deviceInfo = details.info
        isFetchingProfiles = false
    }

    /// A profile was picked: the stream URI of the one picked before it is cleared, so
    /// it can't be saved as this one's. Returns the fetch's ticket.
    mutating func startFetchingStreamURI() -> Int {
        streamURI = nil
        error = nil
        return tickets.issue()
    }

    mutating func streamURIFetched(_ uri: String, ticket: Int) {
        guard tickets.isCurrent(ticket) else { return }
        streamURI = uri
    }

    mutating func fetchFailed(_ message: String, ticket: Int) {
        guard tickets.isCurrent(ticket) else { return }
        error = message
        isFetchingProfiles = false
    }

    /// Whether `ticket` is the latest fetch's, and nothing made it stale since.
    func isCurrent(_ ticket: Int) -> Bool {
        tickets.isCurrent(ticket)
    }
}

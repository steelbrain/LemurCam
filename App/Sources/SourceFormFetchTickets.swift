/// Ties the form's ONVIF fetches to the input they were sent for. Editing the URL
/// while "Connecting…" did not stop the probe, and when it finished it applied
/// the old host: Add then saved host A while the field showed B. Each fetch takes a
/// ticket; a newer fetch, or an edit of the URL (or, for a saved ONVIF camera, of its
/// Host, Port or Use HTTPS), makes the earlier tickets stale, and the result (or
/// error) of a fetch whose ticket is stale is dropped.
internal struct SourceFormFetchTickets {
    private var current = 0

    /// The ticket for a fetch about to start; every earlier one becomes stale.
    mutating func issue() -> Int {
        current += 1
        return current
    }

    /// Makes every ticket issued so far stale.
    mutating func invalidate() {
        current += 1
    }

    func isCurrent(_ ticket: Int) -> Bool {
        ticket == current
    }
}

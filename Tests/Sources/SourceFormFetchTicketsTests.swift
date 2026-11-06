@testable import LemurCam
import XCTest

/// Editing the URL while the form was still connecting to an ONVIF camera let that
/// probe finish and apply the old host, so Add saved host A while the field showed B.
/// `SourceFormFetchTickets` tells the form which finished fetch still applies.
internal final class SourceFormFetchTicketsTests: XCTestCase {
    func testTheLatestFetchApplies() {
        var tickets = SourceFormFetchTickets()
        let probe = tickets.issue()
        XCTAssertTrue(tickets.isCurrent(probe))
    }

    /// The reported case: Connect, then an edit of the URL before the probe ends.
    func testEditingTheURLDropsTheFetchInFlight() {
        var tickets = SourceFormFetchTickets()
        let probe = tickets.issue()

        tickets.invalidate()

        XCTAssertFalse(tickets.isCurrent(probe))
        let probeOfTheNewURL = tickets.issue()
        XCTAssertTrue(tickets.isCurrent(probeOfTheNewURL))
        XCTAssertFalse(tickets.isCurrent(probe), "the old probe stays stale")
    }

    /// A newer fetch (another profile picked, or Fetch Profiles again) supersedes the
    /// one still running, whichever finishes last.
    func testANewerFetchSupersedesTheEarlierOne() {
        var tickets = SourceFormFetchTickets()
        let first = tickets.issue()
        let second = tickets.issue()

        XCTAssertFalse(tickets.isCurrent(first))
        XCTAssertTrue(tickets.isCurrent(second))
    }

    func testAnEditWithNothingInFlightLeavesTheNextFetchCurrent() {
        var tickets = SourceFormFetchTickets()
        tickets.invalidate()
        let probe = tickets.issue()
        XCTAssertTrue(tickets.isCurrent(probe))
    }
}

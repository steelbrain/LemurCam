@testable import LemurCam
import XCTest

/// Locks the traversal semantics of `XMLElement.findElements(named:handler:)` via
/// `ONVIFClient.parseProfiles`, which calls it directly. The subtle, load-bearing
/// behavior is that a *matched* element is NOT recursed into — so a same-named
/// element nested inside a match is never visited. ONVIF parsing depends on this
/// (it would otherwise double-count nested structures), yet nothing pinned it.
internal final class XMLElementFindTests: XCTestCase {
    private var client: ONVIFClient?

    override func setUp() {
        super.setUp()
        client = ONVIFClient(host: "127.0.0.1", port: 80, username: nil, password: nil)
    }

    override func tearDown() {
        client = nil
        super.tearDown()
    }

    /// A `<Profiles>` nested inside another `<Profiles>` must NOT be visited:
    /// findElements stops descending once it matches. If it recursed into matches,
    /// the inner token would be parsed too and the count would be 2.
    func testDoesNotDescendIntoMatchedElements() throws {
        let parser = try XCTUnwrap(client)
        let xml = """
        <GetProfilesResponse>
          <Profiles token="outer">
            <Profiles token="inner"/>
          </Profiles>
        </GetProfilesResponse>
        """

        let profiles = try parser.parseProfiles(Data(xml.utf8))

        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles.first?.token, "outer")
    }

    /// Matches are found at arbitrary depth — findElements recurses through
    /// non-matching ancestors until it hits the target local name.
    func testFindsMatchAtArbitraryDepth() throws {
        let parser = try XCTUnwrap(client)
        let xml = """
        <GetProfilesResponse>
          <Wrapper><Inner><Deeper>
            <Profiles token="deep"/>
          </Deeper></Inner></Wrapper>
        </GetProfilesResponse>
        """

        let profiles = try parser.parseProfiles(Data(xml.utf8))

        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles.first?.token, "deep")
    }

    /// Every sibling match invokes the handler, preserving document order.
    func testVisitsEverySiblingMatchInOrder() throws {
        let parser = try XCTUnwrap(client)
        let xml = """
        <GetProfilesResponse>
          <Profiles token="a"/>
          <Profiles token="b"/>
          <Profiles token="c"/>
        </GetProfilesResponse>
        """

        let profiles = try parser.parseProfiles(Data(xml.utf8))

        XCTAssertEqual(profiles.map(\.token), ["a", "b", "c"])
    }
}

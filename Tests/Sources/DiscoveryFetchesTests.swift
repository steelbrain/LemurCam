@testable import LemurCam
import XCTest

/// The Discover Cameras sheet applied every fetch's reply whenever it came. After
/// Back, picking another camera and Connect, a slow reply from the first camera
/// replaced the second one's profiles and device information, and its manufacturer,
/// model and serial number were saved for the second; picking one profile and then
/// another quickly could save the first one's stream URI as the second's fallback.
/// `DiscoveryFetches` drops the replies of fetches made stale since.
internal final class DiscoveryFetchesTests: XCTestCase {
    private static func details(_ model: String, profiles tokens: [String]) -> ONVIFDeviceDetails {
        ONVIFDeviceDetails(
            profiles: tokens.map { ONVIFProfile(token: $0, name: $0, width: nil, height: nil, codec: nil) },
            info: ONVIFDeviceInfo(
                manufacturer: "Acme", model: model, firmwareVersion: nil, serialNumber: "SN-\(model)", hardwareId: nil
            ),
            endpointReference: nil
        )
    }

    func testTheCurrentFetchesApply() {
        var fetches = DiscoveryFetches()
        let details = fetches.startFetchingDetails()
        XCTAssertTrue(fetches.isFetchingProfiles)

        fetches.detailsFetched(Self.details("A1", profiles: ["main"]), ticket: details)
        XCTAssertFalse(fetches.isFetchingProfiles)
        XCTAssertEqual(fetches.profiles.map(\.token), ["main"])
        XCTAssertEqual(fetches.deviceInfo?.serialNumber, "SN-A1")

        let stream = fetches.startFetchingStreamURI()
        fetches.streamURIFetched("rtsp://192.0.2.5/main", ticket: stream)
        XCTAssertEqual(fetches.streamURI, "rtsp://192.0.2.5/main")
    }

    /// The reported case: Back, another camera, Connect; then the first camera's
    /// slow reply lands.
    func testASlowReplyFromTheCameraPickedBeforeIsDropped() {
        var fetches = DiscoveryFetches()
        let first = fetches.startFetchingDetails()
        fetches.reset()
        let second = fetches.startFetchingDetails()

        fetches.detailsFetched(Self.details("B2", profiles: ["b"]), ticket: second)
        fetches.detailsFetched(Self.details("A1", profiles: ["a"]), ticket: first)
        fetches.fetchFailed("The first camera timed out", ticket: first)

        XCTAssertEqual(fetches.profiles.map(\.token), ["b"])
        XCTAssertEqual(fetches.deviceInfo?.model, "B2")
        XCTAssertEqual(fetches.deviceInfo?.serialNumber, "SN-B2")
        XCTAssertNil(fetches.error)
    }

    /// Back while the profiles are still being fetched leaves nothing behind for the
    /// next camera, even when the second camera's own fetch fails.
    func testBackClearsWhatTheOtherCameraGave() {
        var fetches = DiscoveryFetches()
        let first = fetches.startFetchingDetails()
        fetches.detailsFetched(Self.details("A1", profiles: ["a"]), ticket: first)

        fetches.reset()
        XCTAssertTrue(fetches.profiles.isEmpty)
        XCTAssertNil(fetches.deviceInfo)
        XCTAssertNil(fetches.streamURI)
        XCTAssertFalse(fetches.isFetchingProfiles)

        let second = fetches.startFetchingDetails()
        fetches.fetchFailed("Authentication failed", ticket: second)
        XCTAssertNil(fetches.deviceInfo, "no manufacturer, model or serial from the first camera")
        XCTAssertEqual(fetches.error, "Authentication failed")
        XCTAssertFalse(fetches.isFetchingProfiles)
    }

    /// Picking P1 and then P2 quickly: P1's URI, landing last, is not P2's.
    func testTheStreamURIOfTheProfilePickedBeforeIsDropped() {
        var fetches = DiscoveryFetches()
        let details = fetches.startFetchingDetails()
        fetches.detailsFetched(Self.details("A1", profiles: ["p1", "p2"]), ticket: details)
        let p1 = fetches.startFetchingStreamURI()
        let p2 = fetches.startFetchingStreamURI()

        fetches.streamURIFetched("rtsp://192.0.2.5/p1", ticket: p1)
        XCTAssertNil(fetches.streamURI)

        fetches.streamURIFetched("rtsp://192.0.2.5/p2", ticket: p2)
        XCTAssertEqual(fetches.streamURI, "rtsp://192.0.2.5/p2")
    }

    /// A profile whose own fetch fails is saved without a fallback, not with the URI
    /// of the profile picked before it.
    func testPickingAnotherProfileClearsTheEarlierURI() {
        var fetches = DiscoveryFetches()
        let details = fetches.startFetchingDetails()
        fetches.detailsFetched(Self.details("A1", profiles: ["p1", "p2"]), ticket: details)
        let p1 = fetches.startFetchingStreamURI()
        fetches.streamURIFetched("rtsp://192.0.2.5/p1", ticket: p1)

        let p2 = fetches.startFetchingStreamURI()
        XCTAssertNil(fetches.streamURI)
        fetches.fetchFailed("No answer", ticket: p2)

        XCTAssertNil(fetches.streamURI)
        XCTAssertEqual(fetches.error, "No answer")
        XCTAssertEqual(fetches.profiles.map(\.token), ["p1", "p2"], "the profiles stay")
    }
}

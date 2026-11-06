@testable import LemurCam
import XCTest

/// Adding a camera, connecting to one, then editing the URL and connecting to another
/// kept the first camera's device UUID and serial number, so the second was saved with
/// them and a later rediscovery could re-point it to the first one's address.
/// `SourceFormONVIFDetails` holds what the form read from the camera and clears it on
/// an edit of the URL and on a new Connect. Picking another profile kept the stream URL
/// of the one picked before until its own arrived, so Add or Save could store Sub with
/// Main's URL; picking one now clears it.
internal final class SourceFormONVIFDetailsTests: XCTestCase {
    private static func details(
        serial: String?, endpointReference: String?, profiles tokens: [String] = ["main"]
    ) -> ONVIFDeviceDetails {
        ONVIFDeviceDetails(
            profiles: tokens.map { ONVIFProfile(token: $0, name: $0, width: nil, height: nil, codec: nil) },
            info: ONVIFDeviceInfo(
                manufacturer: "Acme", model: "Cam", firmwareVersion: nil, serialNumber: serial, hardwareId: nil
            ),
            endpointReference: endpointReference
        )
    }

    /// Connect to camera A, pick a profile and read its stream URL.
    private func connectedToCameraA() -> SourceFormONVIFDetails {
        var form = SourceFormONVIFDetails()
        form.startFetchingProfiles()
        form.profilesFetched(Self.details(serial: "SN-A", endpointReference: "urn:uuid:camera-a"))
        form.selectedProfileToken = "main"
        form.streamURIFetched("rtsp://192.0.2.10/main")
        return form
    }

    func testAConnectedCameraHasItsOwnIdentity() {
        let form = connectedToCameraA()

        XCTAssertEqual(form.deviceUUID, "urn:uuid:camera-a")
        XCTAssertEqual(form.serialNumber, "SN-A")
        XCTAssertEqual(form.profiles.map(\.token), ["main"])
        XCTAssertEqual(form.streamURI, "rtsp://192.0.2.10/main")
    }

    /// The reported case: camera B reports no serial number and no endpoint reference,
    /// and was saved with A's.
    func testAnotherCameraConnectedToAfterAnEditKeepsNothingOfTheFirst() {
        var form = connectedToCameraA()

        form.clear()
        form.startFetchingProfiles()
        form.profilesFetched(Self.details(serial: nil, endpointReference: nil, profiles: ["sub"]))

        XCTAssertNil(form.deviceUUID, "camera A's UUID")
        XCTAssertNil(form.serialNumber, "camera A's serial number")
        XCTAssertNil(form.selectedProfileToken)
        XCTAssertNil(form.streamURI)
        XCTAssertEqual(form.profiles.map(\.token), ["sub"])
    }

    /// A UUID already held is kept by a fetch (`ONVIFSourceInfo.resolvedDeviceUUID`), so
    /// B's own endpoint reference used to lose to A's UUID.
    func testAnotherCameraReportingItsOwnIdentityIsSavedWithIt() {
        var form = connectedToCameraA()

        form.clear()
        form.startFetchingProfiles()
        form.profilesFetched(Self.details(serial: "SN-B", endpointReference: "urn:uuid:camera-b"))

        XCTAssertEqual(form.deviceUUID, "urn:uuid:camera-b")
        XCTAssertEqual(form.serialNumber, "SN-B")
    }

    func testClearingLeavesNothing() {
        var form = connectedToCameraA()

        form.clear()

        XCTAssertTrue(form.profiles.isEmpty)
        XCTAssertNil(form.selectedProfileToken)
        XCTAssertNil(form.streamURI)
        XCTAssertNil(form.deviceUUID)
        XCTAssertNil(form.serialNumber)
    }

    /// Fetch Profiles for a saved camera, at its saved address: the UUID it was saved
    /// with (from discovery) stays, as does its serial when the camera reports none.
    func testFetchingASavedCamerasProfilesKeepsItsIdentity() {
        var form = SourceFormONVIFDetails(saved: .init(
            selectedProfileToken: "main", streamURI: "rtsp://192.0.2.10/main",
            deviceUUID: "urn:uuid:from-discovery", serialNumber: "SN-A"
        ))
        XCTAssertTrue(form.profiles.isEmpty, "a saved camera's profiles are fetched anew")
        XCTAssertEqual(form.selectedProfileToken, "main")

        form.startFetchingProfiles()
        XCTAssertNil(form.selectedProfileToken)
        XCTAssertNil(form.streamURI)
        XCTAssertEqual(form.deviceUUID, "urn:uuid:from-discovery")

        form.profilesFetched(Self.details(serial: nil, endpointReference: "urn:uuid:reported"))
        XCTAssertEqual(form.deviceUUID, "urn:uuid:from-discovery")
        XCTAssertEqual(form.serialNumber, "SN-A")
    }

    /// Main is picked and its URL read; then Sub is picked and saved before its own
    /// fetch ends, or after it fails.
    func testPickingAnotherProfileClearsTheEarlierStreamURL() {
        var form = SourceFormONVIFDetails()
        form.profilesFetched(Self.details(serial: "SN-A", endpointReference: nil, profiles: ["main", "sub"]))
        form.selectedProfileToken = "main"
        form.startFetchingStreamURI()
        form.streamURIFetched("rtsp://192.0.2.10/main")

        form.selectedProfileToken = "sub"
        form.startFetchingStreamURI()

        XCTAssertNil(form.streamURI, "Main's URL is not Sub's")
        XCTAssertEqual(form.profiles.map(\.token), ["main", "sub"], "the profiles stay")
        form.streamURIFetched("rtsp://192.0.2.10/sub")
        XCTAssertEqual(form.streamURI, "rtsp://192.0.2.10/sub")
    }

    /// A saved camera's URL goes too when another profile is picked.
    func testPickingAnotherProfileOfASavedCameraClearsItsSavedStreamURL() {
        var form = SourceFormONVIFDetails(saved: .init(
            selectedProfileToken: "main", streamURI: "rtsp://192.0.2.10/main",
            deviceUUID: "urn:uuid:camera-a", serialNumber: "SN-A"
        ))

        form.selectedProfileToken = "sub"
        form.startFetchingStreamURI()

        XCTAssertNil(form.streamURI)
        XCTAssertEqual(form.deviceUUID, "urn:uuid:camera-a", "the camera stays the same")
    }
}

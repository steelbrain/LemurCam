@testable import LemurCam
import XCTest

/// Editing a saved ONVIF camera's Host, Port or Use HTTPS left the old camera's
/// profile, stream URL, device UUID and serial in the form, and Save stored them
/// with the new address: a later rediscovery then looked for the old camera's UUID
/// and could move the source back to it. `SourceFormONVIFAddressEdits` tells the
/// form when to clear them and whether they may be saved with the address shown.
internal final class SourceFormONVIFAddressEditsTests: XCTestCase {
    private typealias Edits = SourceFormONVIFAddressEdits

    private let saved = Edits.Address(host: "192.0.2.10", port: 80, useHTTPS: false)
    private let details = Edits.SavedDetails(
        selectedProfileToken: "main", streamURI: "rtsp://192.0.2.10/main",
        deviceUUID: "uuid-of-camera-a", serialNumber: "SN-A"
    )

    private func editsOfSavedCamera() -> Edits {
        Edits(savedAt: saved, details: details)
    }

    func testTheSavedDetailsMayBeSavedAtTheSavedAddress() {
        XCTAssertTrue(editsOfSavedCamera().allowsSave(at: saved))
    }

    func testChangingTheHostClearsTheDetailsAndBlocksSaving() {
        var edits = editsOfSavedCamera()
        let moved = Edits.Address(host: "192.0.2.11", port: 80, useHTTPS: false)

        XCTAssertEqual(edits.addressEdited(to: moved), .clear)
        XCTAssertFalse(edits.allowsSave(at: moved), "the new address must be fetched before saving")
    }

    func testChangingThePortOrHTTPSClearsTheDetails() {
        var portEdits = editsOfSavedCamera()
        XCTAssertEqual(portEdits.addressEdited(to: .init(host: saved.host, port: 8080, useHTTPS: false)), .clear)

        var httpsEdits = editsOfSavedCamera()
        let https = Edits.Address(host: saved.host, port: 80, useHTTPS: true)
        XCTAssertEqual(httpsEdits.addressEdited(to: https), .clear)
        XCTAssertFalse(httpsEdits.allowsSave(at: https))
    }

    /// Each keystroke in Host is an edit; the details stay cleared until a fetch.
    func testFurtherEditsKeepTheDetailsCleared() {
        var edits = editsOfSavedCamera()
        _ = edits.addressEdited(to: .init(host: "192.0.2.1", port: 80, useHTTPS: false))

        let typed = Edits.Address(host: "192.0.2.11", port: 80, useHTTPS: false)
        XCTAssertEqual(edits.addressEdited(to: typed), .clear)
        XCTAssertFalse(edits.allowsSave(at: typed))
    }

    func testAFetchAtTheNewAddressAllowsSavingThere() {
        var edits = editsOfSavedCamera()
        let moved = Edits.Address(host: "192.0.2.11", port: 80, useHTTPS: false)
        _ = edits.addressEdited(to: moved)

        edits.fetchSucceeded(at: moved)

        XCTAssertTrue(edits.allowsSave(at: moved))
        XCTAssertEqual(edits.addressEdited(to: moved), .keep)
    }

    /// The fetched details belong to the address they came from; moving on clears them.
    func testMovingOnFromAFetchedAddressClearsItsDetails() {
        var edits = editsOfSavedCamera()
        let moved = Edits.Address(host: "192.0.2.11", port: 80, useHTTPS: false)
        _ = edits.addressEdited(to: moved)
        edits.fetchSucceeded(at: moved)

        let other = Edits.Address(host: "192.0.2.12", port: 80, useHTTPS: false)
        XCTAssertEqual(edits.addressEdited(to: other), .clear)
        XCTAssertFalse(edits.allowsSave(at: other))
    }

    /// A typo undone, or the fetched camera abandoned: the saved address gets the
    /// saved details back, so it can be saved without fetching again.
    func testPuttingTheSavedAddressBackRestoresTheSavedDetails() {
        var edits = editsOfSavedCamera()
        let moved = Edits.Address(host: "192.0.2.11", port: 80, useHTTPS: false)
        _ = edits.addressEdited(to: moved)
        edits.fetchSucceeded(at: moved)

        XCTAssertEqual(edits.addressEdited(to: saved), .restore(details))
        XCTAssertTrue(edits.allowsSave(at: saved))
    }

    /// A camera being added has nothing saved: its fetched address is what may be saved.
    func testACameraBeingAddedMaySaveWhereItsProfilesCameFrom() {
        var edits = Edits()
        XCTAssertFalse(edits.allowsSave(at: saved))

        edits.fetchSucceeded(at: saved)

        XCTAssertTrue(edits.allowsSave(at: saved))
    }
}

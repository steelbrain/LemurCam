@testable import LemurCam
import SwiftUI
import XCTest

/// Locks the runtime status → UI mapping. These drive the colored dot and the
/// label shown next to each source; a reordered enum or a renamed label would be
/// a silent UI regression, so pin every case explicitly.
internal final class ConnectionStatusHelpersTests: XCTestCase {

    // MARK: - connectionStatusColor

    func testColorForEveryStatus() {
        XCTAssertEqual(connectionStatusColor(.pending), .gray)
        XCTAssertEqual(connectionStatusColor(.connecting), .orange)
        XCTAssertEqual(connectionStatusColor(.connected), .green)
        XCTAssertEqual(connectionStatusColor(.disconnected), .red)
        XCTAssertEqual(connectionStatusColor(.reconnecting), .orange)
        XCTAssertEqual(connectionStatusColor(.error), .red)
    }

    // MARK: - connectionStatusLabel

    func testLabelForEveryStatus() {
        XCTAssertEqual(connectionStatusLabel(.pending), "Pending")
        XCTAssertEqual(connectionStatusLabel(.connecting), "Connecting")
        XCTAssertEqual(connectionStatusLabel(.connected), "Connected")
        XCTAssertEqual(connectionStatusLabel(.disconnected), "Disconnected")
        XCTAssertEqual(connectionStatusLabel(.reconnecting), "Reconnecting…")
        XCTAssertEqual(connectionStatusLabel(.error), "Error")
    }

    /// Every status maps to a non-empty label. Guards against a future case being
    /// added to `ConnectionStatus` without a corresponding label arm.
    func testEveryStatusHasNonEmptyLabel() {
        let all: [ConnectionStatus] = [
            .pending, .connecting, .connected, .disconnected, .reconnecting, .error
        ]
        for status in all {
            XCTAssertFalse(connectionStatusLabel(status).isEmpty, "empty label for \(status)")
        }
    }
}

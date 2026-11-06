@testable import LemurCam
import XCTest

/// Connect in the Add form moved an RTSP URL's login into the credential fields
/// whole, even when the URL held only part of one: `rtsp://admin@192.0.2.6/s`
/// blanked a typed password, and `rtsp://:pw@192.0.2.6/s` a typed user name. The URL
/// now fills only the parts it holds, as it does when a camera is edited.
internal final class SourceFormCredentialFieldsTests: XCTestCase {
    private let typed = SourceFormCredentialFields(isEnabled: true, username: "viewer", password: "pw")

    private func connect(_ url: String, over fields: SourceFormCredentialFields) -> SourceFormCredentialFields {
        var result = fields
        result.take(SourceCredentials.extractingLoginFromRTSPURL(url).login)
        return result
    }

    func testAUserNameAloneKeepsTheTypedPassword() {
        XCTAssertEqual(
            connect("rtsp://admin@192.0.2.6/s", over: typed),
            SourceFormCredentialFields(isEnabled: true, username: "admin", password: "pw")
        )
    }

    func testAPasswordAloneKeepsTheTypedUserName() {
        XCTAssertEqual(
            connect("rtsp://:n3w@192.0.2.6/s", over: typed),
            SourceFormCredentialFields(isEnabled: true, username: "viewer", password: "n3w")
        )
    }

    func testAWholeLoginReplacesBothFields() {
        XCTAssertEqual(
            connect("rtsp://admin:n3w@192.0.2.6/s", over: typed),
            SourceFormCredentialFields(isEnabled: true, username: "admin", password: "n3w")
        )
        // An empty password written out is the URL's.
        XCTAssertEqual(
            connect("rtsp://admin:@192.0.2.6/s", over: typed),
            SourceFormCredentialFields(isEnabled: true, username: "admin", password: "")
        )
        // A login URLComponents can't read is split at its last `@`.
        XCTAssertEqual(
            connect("rtsp://admin:Adm#1@192.0.2.6/s", over: typed),
            SourceFormCredentialFields(isEnabled: true, username: "admin", password: "Adm#1")
        )
    }

    /// With authentication off, what the hidden fields still hold is not a login:
    /// the part the URL lacks is empty.
    func testFieldsLeftWithAuthenticationOffAreNotReused() {
        let hidden = SourceFormCredentialFields(isEnabled: false, username: "viewer", password: "pw")
        XCTAssertEqual(
            connect("rtsp://admin@192.0.2.6/s", over: hidden),
            SourceFormCredentialFields(isEnabled: true, username: "admin", password: "")
        )
        XCTAssertEqual(
            connect("rtsp://:n3w@192.0.2.6/s", over: hidden),
            SourceFormCredentialFields(isEnabled: true, username: "", password: "n3w")
        )
    }

    func testAURLWithoutALoginChangesNothing() {
        let off = SourceFormCredentialFields(isEnabled: false, username: "", password: "")
        for url in ["rtsp://192.0.2.6/s", "rtsp://@192.0.2.6/s", "rtsp://:@192.0.2.6/s"] {
            XCTAssertEqual(connect(url, over: typed), typed, url)
            XCTAssertEqual(connect(url, over: off), off, url)
        }
    }
}

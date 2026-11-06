@testable import LemurCam
import XCTest

/// Some cameras take their login in the URL's path or query rather than in
/// `user:password@`, and the camera list subtitle and the selectable "Stream URL"
/// labels showed it. Those values are now shown as `***`, by the rules IPCamKit uses
/// in its own messages.
internal final class DisplayedURLTests: XCTestCase {
    /// Xiongmai cameras put the login in a path segment.
    func testLoginInAPathSegmentIsHidden() {
        XCTAssertEqual(
            DisplayedURL.redacted("rtsp://192.0.2.8:554/user=admin_password=s3cret_channel=1_stream=0.sdp"),
            "rtsp://192.0.2.8:554/user=***"
        )
        XCTAssertEqual(DisplayedURL.redacted("rtsp://192.0.2.8/live/pwd=s3cret/main"), "rtsp://192.0.2.8/live/pwd=***/main")
    }

    func testLoginInTheQueryIsHidden() {
        XCTAssertEqual(
            DisplayedURL.redacted("rtsp://192.0.2.8/live?user=admin&password=s3cret&channel=1"),
            "rtsp://192.0.2.8/live?user=***&password=***&channel=1"
        )
        // A `;` may be part of a password: the value runs to the next `&` or `#`.
        XCTAssertEqual(DisplayedURL.redacted("rtsp://192.0.2.8/cgi?channel=1;pwd=s3;cret#main"),
                       "rtsp://192.0.2.8/cgi?channel=1;pwd=***#main")
        XCTAssertEqual(DisplayedURL.redacted("rtsp://192.0.2.8/live?Pass%57ord=s3cret"),
                       "rtsp://192.0.2.8/live?Pass%57ord=***")
        XCTAssertEqual(DisplayedURL.redacted("rtsp://192.0.2.8/live?access_token=abc123"),
                       "rtsp://192.0.2.8/live?access_token=***")
        // A combining mark after a separator does not hide the parameter after it.
        XCTAssertEqual(DisplayedURL.redacted("rtsp://192.0.2.8/live?user=admin&\u{301}password=s3cret"),
                       "rtsp://192.0.2.8/live?user=***&\u{301}password=***")
    }

    func testUserInfoIsStrippedToo() {
        XCTAssertEqual(DisplayedURL.redacted("rtsp://admin:s3cret@192.0.2.8/live?token=abc123"),
                       "rtsp://192.0.2.8/live?token=***")
    }

    /// An `@` in a password in the query or path is not a userinfo `@`. The userinfo
    /// used to be removed first, cut at that `@`, so with a port in the address the
    /// label read `rtsp://2024`: the address gone and the end of the password shown.
    func testAnAtSignInALoginParameterKeepsTheAddress() {
        let cases = [
            "rtsp://192.168.1.5:554/live?user=admin&password=Adm1n@2024":
                "rtsp://192.168.1.5:554/live?user=***&password=***",
            "rtsp://192.168.1.5/live?user=admin&password=Adm1n@2024":
                "rtsp://192.168.1.5/live?user=***&password=***",
            "rtsp://192.168.1.5:554/user=admin_password=Adm1n@2024_channel=1_stream=0.sdp?real_stream":
                "rtsp://192.168.1.5:554/user=***?real_stream",
            "rtsp://192.168.1.5/user=admin_password=Adm1n@2024_channel=1_stream=0.sdp":
                "rtsp://192.168.1.5/user=***",
            "rtsp://admin:s3cret@192.168.1.5:554/live?password=Adm1n@2024":
                "rtsp://192.168.1.5:554/live?password=***"
        ]
        for (url, shown) in cases {
            XCTAssertEqual(DisplayedURL.redacted(url), shown, url)
        }
    }

    /// A login with a raw `/`, `#` or `?` still ends at the last `@`, whether or not
    /// `URLComponents` can read the URL.
    func testALoginWithRawDelimitersIsStillCutAtTheLastAtSign() {
        XCTAssertEqual(DisplayedURL.redacted("rtsp://admin:1234/5@192.168.1.5/live"), "rtsp://192.168.1.5/live")
        XCTAssertEqual(DisplayedURL.redacted("rtsp://admin:1234/5@192.168.1.5/live?pwd=x"),
                       "rtsp://192.168.1.5/live?pwd=***")
        XCTAssertEqual(DisplayedURL.redacted("rtsp://admin:Admin#123@192.168.1.5:554/live"),
                       "rtsp://192.168.1.5:554/live")
    }

    func testURLsWithoutCredentialsAreShownAsTheyAre() {
        for url in [
            "rtsp://192.0.2.8:554/Streaming/Channels/101?transportmode=unicast&profile=Profile_1",
            "rtsp://192.0.2.8/cam/realmonitor?channel=1&subtype=0",
            "rtsps://[fe80::1]:322/stream1",
            "rtsp://192.0.2.8/live/ch00_0"
        ] {
            XCTAssertEqual(DisplayedURL.redacted(url), url)
        }
    }

    func testCredentialParameterNames() {
        let credentialNames = [
            "user", "UserName", "PASSWORD", "pwd", "auth", "access_token", "secret", "usr", "pw", "psw",
            "loginuse", "loginpas", "u%73er"
        ]
        for name in credentialNames {
            XCTAssertTrue(DisplayedURL.isCredentialParameterName(name), name)
        }
        for name in ["channel", "subtype", "stream", "profile", "p", "pws", "port", ""] {
            XCTAssertFalse(DisplayedURL.isCredentialParameterName(name), name)
        }
    }
}

@testable import LemurCam
import XCTest

/// Connect with `rtsp://user:pw@host/...` rewrites the URL field without the
/// credentials. The field's change handler resets the form on user edits, and it used
/// to treat that rewrite as one, clearing the result of Connect and hiding the Add
/// button. `SourceFormURLFieldEdits` lets the handler skip the form's own rewrite.
internal final class SourceFormURLFieldEditsTests: XCTestCase {
    func testTypingIsAUserEdit() {
        var edits = SourceFormURLFieldEdits()
        XCTAssertTrue(edits.isUserEdit("rtsp://192.0.2.8/s"))
    }

    func testFormRewriteIsNotAUserEdit() {
        var edits = SourceFormURLFieldEdits()
        edits.rewrite(to: "rtsp://192.0.2.8/s")
        XCTAssertFalse(edits.isUserEdit("rtsp://192.0.2.8/s"))
    }

    /// Only the one rewrite is skipped; the user's next edit, even back to the same
    /// text, resets the form again.
    func testOnlyTheRewriteItselfIsSkipped() {
        var edits = SourceFormURLFieldEdits()
        edits.rewrite(to: "rtsp://192.0.2.8/s")
        XCTAssertFalse(edits.isUserEdit("rtsp://192.0.2.8/s"))
        XCTAssertTrue(edits.isUserEdit("rtsp://192.0.2.8/s2"))
        XCTAssertTrue(edits.isUserEdit("rtsp://192.0.2.8/s"))
    }

    // MARK: - Surrounding whitespace

    /// Connect checked the trimmed URL but compared the cleaned URL with the trimmed
    /// one, so a URL that only had surrounding spaces was never written back: a
    /// leading space then disabled Add, and a trailing one was saved. The field is now
    /// compared with what it holds.
    func testURLThatOnlyLostItsSpacesIsWrittenBack() {
        var edits = SourceFormURLFieldEdits()
        var field = "  rtsp://192.0.2.8/s \n"
        let cleaned = SourceCredentials.extractingFromRTSPURL(RTSPURLInput.normalized(field)).url

        edits.replace(&field, with: cleaned)

        XCTAssertEqual(field, "rtsp://192.0.2.8/s")
        XCTAssertFalse(edits.isUserEdit(field), "the write-back must not reset the form")
        XCTAssertNil(RTSPURLInput.problem(with: RTSPURLInput.normalized(field)))
    }

    func testCredentialsAndSpacesAreRemovedTogether() {
        var edits = SourceFormURLFieldEdits()
        var field = " rtsp://viewer:pw@192.0.2.8/s "
        let (cleaned, credentials) = SourceCredentials.extractingFromRTSPURL(RTSPURLInput.normalized(field))

        edits.replace(&field, with: cleaned)

        XCTAssertEqual(field, "rtsp://192.0.2.8/s")
        XCTAssertEqual(credentials, SourceCredentials(username: "viewer", password: "pw"))
    }

    /// Nothing to write back: the field is left alone and the user's next edit, even to
    /// the same text, still counts as theirs.
    func testUnchangedFieldIsNotRewritten() {
        var edits = SourceFormURLFieldEdits()
        var field = "rtsp://192.0.2.8/s"

        edits.replace(&field, with: "rtsp://192.0.2.8/s")

        XCTAssertTrue(edits.isUserEdit("rtsp://192.0.2.8/s"))
    }

    /// A leading space made the URL unparseable, which disabled Add without a word.
    func testNormalizedURLPassesTheCheckThatTheRawTextFails() {
        let typed = " rtsp://192.0.2.8/s"
        // Refused for its space now, as IPCamKit refuses one.
        XCTAssertEqual(RTSPURLInput.problem(with: typed), RTSPURLInput.spaceMessage)
        XCTAssertEqual(RTSPURLInput.normalized(typed), "rtsp://192.0.2.8/s")
        XCTAssertNil(RTSPURLInput.problem(with: RTSPURLInput.normalized(typed)))
    }
}

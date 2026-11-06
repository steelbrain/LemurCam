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
}

@testable import LemurCam
import XCTest

/// The edit form stayed open after `EditSavedWithoutLoginError`, though the edit was
/// saved, and its next Save compared against its copy of the camera from before that
/// edit. The form now closes whenever the camera was saved, and the camera list says
/// what is left to do; it stays open, with what was entered, only when nothing was
/// saved. Through the manager: `SourceEditUndoFailureTests`.
internal final class SourceFormSaveOutcomeTests: XCTestCase {
    func testASaveThatWorkedClosesTheForm() {
        let outcome = SourceFormSaveOutcome(error: nil)

        XCTAssertEqual(outcome, .saved)
        XCTAssertTrue(outcome.closesForm)
    }

    /// The reported case: the edit is saved without its login. The form closes and
    /// passes on the error's text, which says what to do.
    func testAnEditSavedWithoutItsLoginClosesTheFormAndSaysWhy() {
        for oldLoginRemoved in [true, false] {
            let error = EditSavedWithoutLoginError(oldLoginRemoved: oldLoginRemoved)

            let outcome = SourceFormSaveOutcome(error: error)

            XCTAssertEqual(outcome, .savedWithProblem(error.localizedDescription))
            XCTAssertTrue(outcome.closesForm, "the edit is saved (old login removed: \(oldLoginRemoved))")
        }
    }

    /// Nothing was saved: the form stays open, with what was entered, and says why.
    func testAFailureThatSavedNothingKeepsTheFormOpen() {
        let errors: [any Error] = [
            CredentialSaveError(), SourceFileSaveError(), SaveRefusedError(refusal: .unreadable),
            URLError(.cannotWriteToFile)
        ]
        for error in errors {
            let outcome = SourceFormSaveOutcome(error: error)

            XCTAssertEqual(outcome, .notSaved(error.localizedDescription), "\(error)")
            XCTAssertFalse(outcome.closesForm, "\(error)")
        }
    }
}

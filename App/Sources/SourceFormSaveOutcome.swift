/// What the add/edit form does once Save or Add returns. The edit form works on a copy
/// of the camera taken when it opened, and passes it to `SourceManager.updateSource`
/// as what it edited (`editedFrom`), so a move WS-Discovery saved since is kept
/// (`SourceType.keepingMove`). After `EditSavedWithoutLoginError` the edit is saved,
/// yet the form stayed open on its old copy: its next Save compared against a camera
/// no longer saved. An ONVIF camera edited from A to B, then back to A, looked moved
/// to B, and was saved at B's address and stream URI with A's profile and device UUID.
/// A Save whose credentials failed again put the file back to the first edit and said
/// the camera wasn't saved, though the first edit is. The form now closes whenever the
/// camera was saved, so the next edit starts from the camera as it is saved.
internal enum SourceFormSaveOutcome: Equatable {
    /// Saved: the form closes.
    case saved
    /// Saved, with a problem the user has to act on: the form closes and the camera
    /// list shows it.
    case savedWithProblem(SavedEditProblem)
    /// Nothing was saved: the form stays open with what was entered and shows `message`.
    case notSaved(String)

    /// The outcome of a save that threw `error`, or of one that worked when nil.
    init(error: (any Error)?) {
        switch error {
        case nil:
            self = .saved
        case let error as EditSavedWithoutLoginError:
            self = .savedWithProblem(SavedEditProblem(title: "Login Not Saved", message: error.localizedDescription))
        case let error as EditSavedWithOldLoginError:
            self = .savedWithProblem(SavedEditProblem(title: "Login Not Removed", message: error.localizedDescription))
        case let error?:
            self = .notSaved(error.localizedDescription)
        }
    }

    /// Whether the form closes: the camera was saved.
    var closesForm: Bool {
        switch self {
        case .saved, .savedWithProblem: true
        case .notSaved: false
        }
    }
}

/// What the camera list shows about an edit saved with a problem: an alert `title`
/// and `message`. The list showed "Login Not Saved" for every such edit, also for
/// `EditSavedWithOldLoginError`, where the login the user turned off is still saved.
internal struct SavedEditProblem: Equatable {
    let title: String
    let message: String
}

import Foundation

/// An edit turned a camera's login off, and the Keychain couldn't remove it, so the
/// edit was undone (`SourceManager.updateSource`). Saved anyway, the old login stayed
/// with the edited camera, and went to its new address if the edit changed it.
internal struct CredentialRemoveError: LocalizedError {
    var errorDescription: String? {
        "The username and password couldn't be removed from the Keychain, so the camera wasn't saved. Try again."
    }
}

/// An edit turned a camera's login off, the Keychain couldn't remove it, and the
/// cameras file couldn't be put back either. The camera stays as edited, with its old
/// login still in the Keychain. The edit is saved, so the edit form closes and the
/// camera list shows this (`SourceFormSaveOutcome`).
internal struct EditSavedWithOldLoginError: LocalizedError {
    var errorDescription: String? {
        "The camera was saved, but its old username and password couldn't be removed from the Keychain, and "
            + "the change couldn't be undone. Edit the camera to remove them again, or delete it."
    }
}

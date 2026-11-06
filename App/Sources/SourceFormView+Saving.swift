// What the add/edit form needs that none of its state does: the camera it edits and
// the manager it saves to. Kept apart so the form's file stays within its length limit.
extension SourceFormView {
    /// Adds the camera, or saves the edit of `editing`, and returns what the form does
    /// next (`SourceFormSaveOutcome`).
    func store(name: String, sourceType: SourceType, credentials change: CredentialChange) -> SourceFormSaveOutcome {
        do {
            if let source = editing {
                // What the form loaded, so a move WS-Discovery saved since is kept. The
                // form closes once it saved the camera, so no save of its own came since.
                try sourceManager.updateSource(
                    id: source.id, name: name, sourceType: sourceType, credentials: change,
                    editedFrom: source.sourceType
                )
            } else {
                let credentials: SourceCredentials? = if case .set(let entered) = change { entered } else { nil }
                try sourceManager.addSource(name: name, sourceType: sourceType, credentials: credentials)
            }
            return SourceFormSaveOutcome(error: nil)
        } catch {
            return SourceFormSaveOutcome(error: error)
        }
    }

    /// The camera being edited, as saved, when it is an ONVIF camera.
    var savedONVIFInfo: ONVIFSourceInfo? {
        guard case .onvif(let info)? = editing?.sourceType else { return nil }
        return info
    }
}

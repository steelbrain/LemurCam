/// The edit form works on a copy of the camera taken when it opened. WS-Discovery can
/// find an ONVIF camera at another address meanwhile and save that address
/// (`SourceManager.updateONVIFAddress`), with the stored stream URI rewritten to name
/// it. Saving the form then wrote the address the camera left, and the stored URI
/// naming it, back over the move, so the saved login went to whatever device answers
/// there now, or the wrong camera streamed. Renaming the camera was enough, or just
/// pressing Return: Save is the default button, and the address and profile the form
/// loaded are valid.
extension SourceType {
    /// This edited type, with the address saved now kept when the edit left the
    /// address the form loaded (`loaded`) as it was and the camera was moved since
    /// (`saved`): host, port and HTTPS, and the stored stream URI. A stream URI the
    /// form fetched since (another profile picked) follows the move as a move's does
    /// (`SourceCredentials.storedStreamURI(_:movedFrom:to:)`). Everything else is the
    /// form's: the move changes nothing else. An address the user edited wins, and so
    /// does any other type.
    func keepingMove(savedSince loaded: SourceType, now saved: SourceType) -> SourceType {
        guard case .onvif(var edited) = self, case .onvif(let before) = loaded, case .onvif(let now) = saved,
              edited.hasAddress(of: before), !now.hasAddress(of: before) else { return self }
        if edited.streamURI == before.streamURI {
            edited.streamURI = now.streamURI
        } else {
            edited.streamURI = edited.streamURI.flatMap {
                SourceCredentials.storedStreamURI($0, movedFrom: before.host, to: now.host)
            }
        }
        edited.host = now.host
        edited.port = now.port
        edited.useHTTPS = now.useHTTPS
        return .onvif(edited)
    }
}

extension ONVIFSourceInfo {
    /// Whether this is saved at `other`'s address: the same host, port and HTTPS.
    func hasAddress(of other: Self) -> Bool {
        host == other.host && port == other.port && useHTTPS == other.useHTTPS
    }
}

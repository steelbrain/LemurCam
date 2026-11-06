/// The form's Requires Authentication toggle and credential fields, as Connect fills
/// them from the login in an RTSP URL. That login is often only part of one, and
/// Connect replaced both fields with it: `rtsp://admin@192.0.2.6/s` blanked a typed
/// password, `rtsp://:pw@192.0.2.6/s` a typed user name. The URL now wins only for
/// the parts it holds, as it does when a camera is edited (`CredentialChange.merging`):
/// a part it lacks keeps what was typed, or is empty when authentication was off.
internal struct SourceFormCredentialFields: Equatable {
    var isEnabled: Bool
    var username: String
    var password: String

    /// Takes the parts of `login` the URL holds; nil (no login) changes nothing.
    mutating func take(_ login: URLLogin?) {
        guard let login else { return }
        let typed = CredentialChange.fromForm(
            authenticationEnabled: isEnabled, username: username, password: password,
            storedCredentialsUnreadable: false
        )
        guard case .set(let merged) = typed.merging(login, stored: { nil }) else { return }
        isEnabled = true
        username = merged.username
        password = merged.password
    }
}

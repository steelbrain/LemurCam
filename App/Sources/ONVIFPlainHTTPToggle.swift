import SwiftUI

/// The per-camera checkbox that lets ONVIF requests go over plain HTTP to an address
/// outside the local network (`ONVIFLocalNetwork`), with what that exposes. Shown only
/// for such an address. The client signs each request with a WS-Security
/// UsernameToken: the user name in clear and a password digest (SHA-1 of a nonce, a
/// timestamp and the password) that can be tested against password guesses offline.
/// It sends no HTTP authentication, so no password goes in clear; the camera's
/// replies (its profiles, device information and stream address) do.
internal struct ONVIFPlainHTTPToggle: View {
    let host: String
    let useHTTPS: Bool
    @Binding var isOn: Bool

    var body: some View {
        if !host.isEmpty, ONVIFLocalNetwork.needsPlainHTTPAllowance(host: host, useHTTPS: useHTTPS) {
            Toggle(ONVIFLocalNetwork.allowanceName, isOn: $isOn)
            Text("This address is outside your local network. Over HTTP, your username, a hash of your "
                 + "password that can be guessed offline, and the camera's replies travel unencrypted.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

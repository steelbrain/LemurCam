import SwiftUI

/// What the add/edit form and the Discover sheet ask when a fetch met a certificate
/// macOS doesn't trust (`ONVIFError.certificateNotTrusted`): whether to trust it, with
/// the camera's host and the certificate's SHA-256 fingerprint. Trust saves the
/// fingerprint with the camera (trust on first use) and fetches again; from then on
/// that certificate, and only that one, is accepted from the camera.
internal struct CertificateTrustPrompt: Identifiable {
    /// What the form shows under the fetch while the question is open, and after
    /// Cancel. Trust fetches again, which clears it.
    static let notTrustedMessage = "Not connected: the camera's certificate wasn't trusted."

    let problem: ONVIFCertificateProblem
    /// The ticket of the fetch that met the certificate. Trust does nothing for a fetch
    /// made stale since (the address was edited, say).
    let ticket: Int

    var id: Int { ticket }

    /// Nil unless `error` is a refused certificate.
    init?(error: any Error, ticket: Int) {
        guard case .certificateNotTrusted(let problem)? = error as? ONVIFError else { return nil }
        self.problem = problem
        self.ticket = ticket
    }

    var title: String {
        switch problem.kind {
        case .untrusted: "Trust the certificate of \(problem.host)?"
        case .changed: "Trust the new certificate of \(problem.host)?"
        }
    }

    var message: String {
        let fingerprint = problem.fingerprint.formatted
        switch problem.kind {
        case .untrusted:
            return "macOS doesn't trust the certificate this camera presented; cameras usually sign their own. "
                + "Trust it if this SHA-256 fingerprint is the camera's:\n\n\(fingerprint)"
        case .changed:
            return "This camera presented a different certificate from the one you trusted. Trust it only if "
                + "you reset the camera or changed its certificate. SHA-256 fingerprint:\n\n\(fingerprint)"
        }
    }
}

extension View {
    /// Shows `prompt` while it is set, with Trust, which calls `onTrust`, and Cancel.
    /// Either answer clears it.
    func certificateTrustDialog(
        _ prompt: Binding<CertificateTrustPrompt?>, onTrust: @escaping (CertificateTrustPrompt) -> Void
    ) -> some View {
        confirmationDialog(
            prompt.wrappedValue?.title ?? "",
            isPresented: Binding(
                get: { prompt.wrappedValue != nil },
                set: { if !$0 { prompt.wrappedValue = nil } }
            ),
            titleVisibility: .visible,
            presenting: prompt.wrappedValue
        ) { shown in
            Button("Trust") { onTrust(shown) }
            Button("Cancel", role: .cancel) { prompt.wrappedValue = nil }
        } message: { shown in
            Text(shown.message)
        }
    }
}

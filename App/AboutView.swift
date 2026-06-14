import SwiftUI

/// A compact custom About card. We render this instead of
/// `NSApplication.orderFrontStandardAboutPanel` because the standard panel's
/// credits text view doesn't reliably make `.link` attributes clickable; a
/// SwiftUI `Link` always opens in the browser.
internal struct AboutView: View {
    private static let siteURL = URL(string: "https://lemur.cam")
    private static let authorURL = URL(string: "https://aneesiqbal.ai")

    var body: some View {
        VStack(spacing: 12) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 96, height: 96)
            }

            VStack(spacing: 2) {
                Text("LemurCam")
                    .font(.title.bold())
                Text("Version \(Bundle.main.shortVersion)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text("Turn an IP camera into a virtual webcam.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 6) {
                Text("by")
                    .foregroundStyle(.secondary)
                if let authorURL = Self.authorURL {
                    Link("Anees Iqbal", destination: authorURL)
                }
                Text("·")
                    .foregroundStyle(.secondary)
                if let siteURL = Self.siteURL {
                    Link("lemur.cam", destination: siteURL)
                }
            }
            .font(.callout)
        }
        .padding(24)
        .frame(width: Tuning.aboutWindowWidth, height: Tuning.aboutWindowHeight)
    }
}

internal extension Bundle {
    var shortVersion: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }
}

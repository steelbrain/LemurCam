import SwiftUI

/// Inline warning shown in the popover when an active LAN camera can't be reached —
/// most often the macOS Local Network permission, which has no queryable API. Offers
/// a deep link to the Privacy & Security → Local Network pane to fix it. The decision
/// to show it lives in `LocalNetworkGuidance`.
internal struct LocalNetworkWarningBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "wifi.exclamationmark")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Can’t reach this camera on your network")
                    .font(.caption.weight(.medium))
                Text("LemurCam may need Local Network access.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button("Open Privacy Settings") {
                    if let url = URL(string: LocalNetworkGuidance.settingsURLString) {
                        NSWorkspace.shared.open(url)
                    }
                }
                .font(.caption2)
                .buttonStyle(.link)
                .padding(.top, 1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }
}

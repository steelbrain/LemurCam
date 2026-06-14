import SwiftUI

/// The proactive launch banner shown when an in-place upgrade left the camera
/// needing a restart the user might otherwise miss. Content is driven by a pure
/// `LaunchNudge`; the hosting window (`AppDelegate`) decides when to present it.
internal struct LaunchNudgeView: View {
    let nudge: LaunchNudge
    let onRestart: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.clockwise.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Later", action: onDismiss)
                if nudge == .appRestart {
                    Button("Restart LemurCam", action: onRestart)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(.top, 4)
        }
        .padding(28)
        .frame(width: Tuning.launchNudgeWindowWidth)
    }

    private var title: String {
        switch nudge {
        case .appRestart: return "Finish Updating LemurCam"
        case .reboot: return "Restart Your Mac"
        }
    }

    private var message: String {
        switch nudge {
        case .appRestart:
            return "LemurCam updated. Restart the app to start using the new camera. "
                + "Only the app restarts, not your Mac."
        case .reboot:
            return "Restart your Mac to finish updating the LemurCam camera."
        }
    }
}

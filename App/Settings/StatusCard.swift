import SwiftUI

/// A compact device-status card for Settings → Setup & Status. Shares the guided
/// wizard's visual language (a logo-tinted tile + an animated status glyph) but in a
/// horizontal, at-a-glance layout suited to the ongoing manage-everything surface.
///
/// Purely presentational: the owner maps its domain status to a `SetupStepState`,
/// a short status word, a subtitle, and an optional contextual action control.
/// Status and copy changes animate.
internal struct StatusCard: View {
    let symbol: String
    let title: String
    let subtitle: String
    let state: SetupStepState
    let statusText: String
    /// The contextual action (enable / approve / restart / repair …), or `nil` when
    /// the state needs no action — the card then renders without an action footer.
    let action: AnyView?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                tile
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(title).font(.headline)
                        Spacer(minLength: 8)
                        statusBadge
                    }
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let action {
                Divider().padding(.top, 14)
                action.padding(.top, 12)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06))
        )
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: state)
    }

    private var tile: some View {
        RoundedRectangle(cornerRadius: 13, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Color.accentColor, Color.accentColor.opacity(0.65)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: 52, height: 52)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.18), radius: 1, y: 1)
            )
            .shadow(color: Color.accentColor.opacity(0.25), radius: 6, y: 2)
    }

    private var statusBadge: some View {
        HStack(spacing: 5) {
            statusGlyph
            Text(statusText)
                .font(.subheadline.weight(.medium))
        }
        .foregroundStyle(state.statusTint)
        .contentTransition(.opacity)
        .id(statusText)
    }

    @ViewBuilder
    private var statusGlyph: some View {
        switch state {
        case .inactive:
            Image(systemName: "circle")
        case .working:
            ProgressView().controlSize(.small)
        case .actionNeeded:
            Image(systemName: "exclamationmark.circle.fill")
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .symbolEffect(.bounce, value: state)
        case .failed:
            Image(systemName: "xmark.circle.fill")
        }
    }
}

internal extension SetupStepState {
    /// The accent color the status badge uses for this state. Mirrors the wizard's
    /// indicator palette so both surfaces read the same.
    var statusTint: Color {
        switch self {
        case .inactive, .working: return .secondary
        case .actionNeeded: return .orange
        case .ready: return .green
        case .failed: return .red
        }
    }
}

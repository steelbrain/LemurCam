import SwiftUI

/// Semantic state of a setup step's device, independent of the underlying
/// camera/mic status enums. Drives the hero's animated status indicator.
internal enum SetupStepState: Equatable {
    /// Nothing wrong yet — a normal to-do (e.g. no camera added). Neutral.
    case inactive
    /// A request is in flight (installing / querying). Spinner.
    case working
    /// Needs a user action (approve, enable, restart, repair). Amber.
    case actionNeeded
    /// Done and healthy. Green check.
    case ready
    /// Failed. Red.
    case failed
}

/// The centered "device hero" at the heart of each wizard step: a logo-tinted tile
/// with the device glyph, an animated corner status indicator, the title, and the
/// detail copy. Purely presentational — the owner supplies the state and the action
/// control beneath it.
///
/// Motion is layered so each state earns a reaction: the tile *arrives* (scale+fade
/// on appear), *breathes* while working, *settles* with a bounce and a green halo
/// when a step completes, and its glow/tint tracks the state. None of this touches
/// setup logic — it animates state the owner already computed.
internal struct SetupDeviceHero: View {
    let symbol: String
    let title: String
    let detail: String
    let state: SetupStepState

    /// Drives the one-shot entrance (scale+fade) the first time the hero appears.
    @State private var entered = false
    /// Toggled once on appear to start the continuous "breathing" halo loop; the
    /// halo's visibility is gated on `.working`, so the loop is invisible otherwise.
    @State private var breathing = false

    private var isReady: Bool { state == .ready }

    var body: some View {
        VStack(spacing: 16) {
            heroTile
            VStack(spacing: 6) {
                Text(title)
                    .font(.title2.bold())
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 360)
                    .contentTransition(.opacity)
                    .id(detail)
            }
        }
        .scaleEffect(entered ? 1 : 0.94)
        .opacity(entered ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) { entered = true }
            breathing = true
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.7), value: state)
        .animation(.easeInOut(duration: 0.25), value: detail)
    }

    private var heroTile: some View {
        ZStack {
            breathingHalo
            completionRing
            ZStack(alignment: .bottomTrailing) {
                tile
                statusIndicator
                    .offset(x: 7, y: 7)
            }
        }
    }

    private var tile: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(tileGradient)
            .frame(width: 88, height: 88)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: 40, weight: .medium))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.18), radius: 1, y: 1)
            )
            .shadow(color: stateColor.opacity(0.3), radius: 11, y: 4)
            .phaseAnimator([1.0, 1.1, 1.0], trigger: isReady) { content, scale in
                content.scaleEffect(scale)
            } animation: { _ in .spring(response: 0.32, dampingFraction: 0.55) }
    }

    /// A soft blurred glow behind the tile that slowly pulses while a request is in
    /// flight, so the wait reads as alive. Faded out (animated) when not working.
    private var breathingHalo: some View {
        RoundedRectangle(cornerRadius: 26, style: .continuous)
            .fill(Color.accentColor.opacity(0.22))
            .frame(width: 88, height: 88)
            .blur(radius: 13)
            .scaleEffect(breathing ? 1.18 : 0.92)
            .opacity(state == .working ? 1 : 0)
            .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: breathing)
    }

    /// A green ring that flashes in and expands outward once when the step reaches
    /// `.ready` — the completion payoff. Invisible at rest (both the first and last
    /// phase have zero opacity), so it only shows during the burst.
    private var completionRing: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .stroke(Color.green, lineWidth: 3)
            .frame(width: 88, height: 88)
            .phaseAnimator(RingPhase.allCases, trigger: isReady) { content, phase in
                content
                    .scaleEffect(phase.scale)
                    .opacity(phase.opacity)
            } animation: { phase in phase.animation }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch state {
        case .inactive:
            EmptyView()
        case .working:
            ProgressView()
                .controlSize(.small)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                .overlay(Circle().strokeBorder(Color.gray.opacity(0.2)))
                .transition(.opacity)
        case .actionNeeded:
            indicatorSymbol("exclamationmark.circle.fill", .orange)
        case .ready:
            indicatorSymbol("checkmark.circle.fill", .green)
                .symbolEffect(.bounce, value: state)
        case .failed:
            indicatorSymbol("xmark.circle.fill", .red)
        }
    }

    /// A filled status glyph on a white disc so it reads on any tile color.
    private func indicatorSymbol(_ name: String, _ color: Color) -> some View {
        Image(systemName: name)
            .resizable()
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, color)
            .frame(width: 26, height: 26)
            .background(Circle().fill(.white).padding(2))
            .transition(.scale.combined(with: .opacity))
    }

    /// The tile's tint follows the state: brand accent for to-do / in-progress,
    /// green on success, red on failure. Also drives the glow color.
    private var stateColor: Color {
        switch state {
        case .ready: return .green
        case .failed: return .red
        case .inactive, .working, .actionNeeded: return .accentColor
        }
    }

    private var tileGradient: LinearGradient {
        LinearGradient(
            colors: [stateColor, stateColor.opacity(0.65)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

/// Phases of the one-shot completion ring. Ordered hidden → flash → expand so the
/// ring pops in quickly then expands and fades; both endpoints are invisible, so it
/// is unseen except during the burst right after a step reaches `.ready`.
private enum RingPhase: CaseIterable {
    case hidden, flash, expand

    var scale: CGFloat {
        switch self {
        case .hidden, .flash: return 1.0
        case .expand: return 1.65
        }
    }

    var opacity: Double {
        switch self {
        case .hidden, .expand: return 0
        case .flash: return 0.65
        }
    }

    var animation: Animation? {
        switch self {
        case .hidden: return nil
        case .flash: return .easeOut(duration: 0.12)
        case .expand: return .easeOut(duration: 0.6)
        }
    }
}

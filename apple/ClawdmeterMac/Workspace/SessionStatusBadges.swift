import SwiftUI
import ClawdmeterShared

/// Small leaf views used across the sidebar + workspace switcher to
/// surface per-session status: pulse dots for live sessions, attention
/// badges for "agent needs you", hover-action buttons (pin/mute/archive),
/// and the connecting-spinner state.
///
/// Lifted out of `SessionWorkspaceView.swift` by **A6 (foundation)** —
/// see .claude/plans/study-this-codebase-crystalline-shore.md. Every
/// view here is a leaf with explicit init args + at most one `@State`
/// of its own; isolating them removes lexical coupling without changing
/// observed-state graphs.

/// A pulsing dot used as the "session is live" affordance. Concentric
/// ring expands and fades to draw the eye; respects Reduce Motion.
struct StatusPulseDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let color: Color
    let isLive: Bool
    @State private var pulse = false

    var body: some View {
        ZStack {
            if isLive && !reduceMotion {
                Circle()
                    .stroke(color.opacity(0.35), lineWidth: 1.5)
                    .frame(width: pulse ? 14 : 7, height: pulse ? 14 : 7)
                    .opacity(pulse ? 0 : 1)
            }
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
        }
        .frame(width: 14, height: 14)
        .onAppear {
            guard isLive, !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.3).repeatForever(autoreverses: false)) {
                pulse = true
            }
        }
        .onChange(of: isLive) { _, newValue in
            pulse = false
            guard newValue, !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.3).repeatForever(autoreverses: false)) {
                pulse = true
            }
        }
        .onChange(of: reduceMotion) { _, newValue in
            if newValue { pulse = false }
        }
    }
}

/// Small color-coded glyph indicating why a session needs the user's
/// attention. `AttentionReason` lives in ClawdmeterShared/UI.
struct AttentionBadge: View {
    let reason: AttentionReason

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 15, height: 15)
            .background(tint.opacity(0.13), in: Circle())
            .help(reason.label)
            .accessibilityLabel(reason.label)
    }

    private var icon: String {
        switch reason {
        case .awaitingInput: return "hand.raised.fill"
        case .planReady: return "doc.text.fill"
        case .pullRequest: return "arrow.triangle.pull"
        case .checksFailed: return "xmark.octagon.fill"
        case .providerBlocked: return "lock.fill"
        case .unread: return "circle.fill"
        case .outboxPending: return "tray.and.arrow.down.fill"
        case .degraded: return "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch reason {
        case .checksFailed, .providerBlocked, .degraded: return .red
        case .awaitingInput, .planReady: return .orange
        case .pullRequest, .outboxPending: return .blue
        case .unread: return .accentColor
        }
    }
}

/// Pin / mute / archive triplet shown when the user hovers a sidebar
/// row. Pure-closure surface — the parent owns all the side-effects.
struct SessionHoverActions: View {
    let isPinned: Bool
    let isMuted: Bool
    let onPin: () -> Void
    let onMute: () -> Void
    let onArchive: () -> Void

    var body: some View {
        HStack(spacing: 3) {
            hoverButton(icon: isPinned ? "pin.slash" : "pin", label: isPinned ? "Unpin" : "Pin", action: onPin)
            hoverButton(icon: isMuted ? "bell" : "bell.slash", label: isMuted ? "Unmute" : "Mute", action: onMute)
            hoverButton(icon: "archivebox", label: "Archive", action: onArchive)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func hoverButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .codeHoverChrome(
            cornerRadius: 5,
            help: label,
            accessibilityLabel: label,
            accessibilityIdentifier: "code.session.action.\(label.lowercased().replacingOccurrences(of: " ", with: "-"))"
        )
    }
}

/// Placeholder state shown while the daemon is wiring up a new session's
/// transcript stream. Renders only static props (session metadata) plus
/// one decorative `StatusPulseDot` — fully independent of the parent.
struct ConnectingTranscriptState: View {
    let session: AgentSession

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                StatusPulseDot(color: .green, isLive: true)
                    .scaleEffect(1.8)
                Image(systemName: "sparkle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 48, height: 48)
            Text("Connecting to \(session.agent.rawValue.capitalized)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
            Text(session.effectiveCwd)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 440)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

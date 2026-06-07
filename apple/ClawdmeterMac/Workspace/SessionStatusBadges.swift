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
        case .checksFailed, .providerBlocked, .degraded: return SessionsV2Theme.danger
        case .awaitingInput, .planReady: return SessionsV2Theme.warn
        case .pullRequest, .outboxPending: return SessionsV2Theme.codexBlue
        case .unread: return SessionsV2Theme.accent
        }
    }
}

/// Archive action shown when the user hovers a sidebar row. Archive is the
/// only hover action (pin/mute were removed — they cluttered the row and live
/// in the right-click menu). Sized 22×22 — at or below the row's natural
/// content height — so revealing it on hover does NOT grow the row.
/// Pure-closure surface; the parent owns the side-effect.
struct SessionHoverActions: View {
    let onArchive: () -> Void

    var body: some View {
        // Bare archive glyph (Conductor-style) revealed on row hover. The
        // always-on chip background was dropped so it reads as a light
        // affordance, not a heavy button; `codeHoverChrome` still draws a
        // subtle highlight when the cursor is on the glyph itself.
        Button(action: onArchive) {
            Image(systemName: "archivebox")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .codeHoverChrome(
            cornerRadius: 6,
            help: "Archive",
            accessibilityLabel: "Archive",
            accessibilityIdentifier: "code.session.action.archive"
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
            // The composer below is already live — encourage the user to start
            // writing while the agent finishes booting; the first send queues and
            // delivers as soon as it's ready.
            Text("Go ahead and type your prompt below — it'll send the moment \(session.agent.rawValue.capitalized) is ready.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .padding(.top, 2)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

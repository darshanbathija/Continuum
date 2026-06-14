import SwiftUI
import ClawdmeterShared

/// Small leaf views used across the sidebar + workspace switcher to
/// surface per-session status: pulse dots for live sessions, attention
/// badges for "agent needs you", hover-action buttons (pin/mute/archive),
/// and the transcript empty-state placeholder.
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
/// Conductor-style `+N -M` badge for a worktree's diff against the default branch.
struct WorktreeDiffBadge: View {
    @Environment(\.tahoe) private var t
    let stat: WorktreeDiffStat
    /// Selected/open rows tint the deltas; idle rows stay muted.
    let emphasized: Bool

    var body: some View {
        HStack(spacing: 4) {
            if stat.additions > 0 {
                Text("+\(WorktreeDiffFormatting.compactCount(stat.additions))")
                    .foregroundStyle(emphasized ? Self.additionsTint : t.fg3)
            }
            if stat.deletions > 0 {
                Text("-\(WorktreeDiffFormatting.compactCount(stat.deletions))")
                    .foregroundStyle(emphasized ? Self.deletionsTint : t.fg3)
            }
        }
        .font(TahoeFont.body(9.5, weight: .semibold))
        .monospacedDigit()
        .accessibilityIdentifier("code.worktree.diff")
        .accessibilityLabel(diffAccessibilityLabel)
    }

    private var diffAccessibilityLabel: String {
        var parts: [String] = []
        if stat.additions > 0 { parts.append("\(stat.additions) additions") }
        if stat.deletions > 0 { parts.append("\(stat.deletions) deletions") }
        return parts.isEmpty ? "No diff" : parts.joined(separator: ", ")
    }

    private static let additionsTint = Color(red: 0x52 / 255.0, green: 0xC4 / 255.0, blue: 0x1A / 255.0)
    private static let deletionsTint = Color(red: 0xE6 / 255.0, green: 0x4B / 255.0, blue: 0x4B / 255.0)
}

struct SessionHoverActions: View {
    let onArchive: () -> Void

    var body: some View {
        // Bare archive glyph (Conductor-style) revealed on row hover. The
        // always-on chip background was dropped so it reads as a light
        // affordance, not a heavy button; `codeHoverChrome` still draws a
        // subtle highlight when the cursor is on the glyph itself.
        Button(action: ContinuumAnalytics.wrapButton("archive_session", onArchive)) {
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
        // Clickable-hand cursor on the glyph; the row's open button already
        // sets `.link`, but this sibling button would otherwise revert to arrow.
        .pointerStyle(.link)
    }
}

/// Hairline corner brackets framing the empty workspace — reads as a blank
/// canvas without reusing the app icon.
private struct TranscriptCanvasBracketShape: Shape {
    let inset: CGFloat
    let leg: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let x0 = rect.minX + inset
        let y0 = rect.minY + inset
        let x1 = rect.maxX - inset
        let y1 = rect.maxY - inset

        path.move(to: CGPoint(x: x0, y: y0 + leg))
        path.addLine(to: CGPoint(x: x0, y: y0))
        path.addLine(to: CGPoint(x: x0 + leg, y: y0))

        path.move(to: CGPoint(x: x1 - leg, y: y0))
        path.addLine(to: CGPoint(x: x1, y: y0))
        path.addLine(to: CGPoint(x: x1, y: y0 + leg))

        path.move(to: CGPoint(x: x1, y: y1 - leg))
        path.addLine(to: CGPoint(x: x1, y: y1))
        path.addLine(to: CGPoint(x: x1 - leg, y: y1))

        path.move(to: CGPoint(x: x0 + leg, y: y1))
        path.addLine(to: CGPoint(x: x0, y: y1))
        path.addLine(to: CGPoint(x: x0, y: y1 - leg))

        return path
    }
}

/// Custom empty-canvas glyph — bracket frame + bold plus. Scales in once on
/// appear; no app-logo recycling.
private struct TranscriptCanvasMark: View {
    let size: CGFloat
    @Environment(\.tahoe) private var t

    private var inset: CGFloat { size * 0.06 }
    private var leg: CGFloat { size * 0.22 }

    var body: some View {
        ZStack {
            TranscriptCanvasBracketShape(inset: inset, leg: leg)
                .stroke(t.fg3, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))

            Text("+")
                .font(TahoeFont.rounded(size * 0.42, weight: .light))
                .foregroundStyle(t.fg)
                .offset(y: -size * 0.02)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Bold canvas placeholder for an empty session transcript — the center
/// thread before the first turn lands. Custom bracket mark scales in once;
/// headline reads bright against dim chrome.
struct TranscriptEmptyState: View {
    enum Style {
        /// Centered hero overlay — full session canvas.
        case canvas
        /// Compact row under "Load earlier" when history exists off-screen.
        case inline
    }

    var style: Style = .canvas

    @Environment(\.tahoe) private var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var markAppeared = false
    @State private var copyAppeared = false

    var body: some View {
        switch style {
        case .canvas:
            canvasBody
        case .inline:
            inlineBody
        }
    }

    private var canvasBody: some View {
        VStack(spacing: 32) {
            canvasMark(size: 96)
            Text("Build something great")
                .font(TahoeFont.rounded(40, weight: .bold))
                .foregroundStyle(t.fg)
                .multilineTextAlignment(.center)
                .opacity(copyAppeared ? 1 : 0)
                .offset(y: (copyAppeared || reduceMotion) ? 0 : 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { runCanvasEntrance() }
    }

    private var inlineBody: some View {
        VStack(spacing: 10) {
            canvasMark(size: 44)
            Text("Build something great")
                .font(TahoeFont.rounded(20, weight: .semibold))
                .foregroundStyle(t.fg2)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 36)
        .frame(maxWidth: .infinity)
    }

    private func canvasMark(size: CGFloat) -> some View {
        TranscriptCanvasMark(size: size)
            .scaleEffect(markAppeared || style == .inline ? 1 : (reduceMotion ? 1 : 0.68))
            .opacity(markAppeared || style == .inline ? 1 : 0)
    }

    private func runCanvasEntrance() {
        guard style == .canvas else { return }
        withAnimation(SessionsV2Theme.bannerSlideUp(reduceMotion: reduceMotion)) {
            markAppeared = true
        }
        let textDelay = reduceMotion ? 0 : 0.14
        DispatchQueue.main.asyncAfter(deadline: .now() + textDelay) {
            withAnimation(SessionsV2Theme.bannerSlideUp(reduceMotion: reduceMotion)) {
                copyAppeared = true
            }
        }
    }
}

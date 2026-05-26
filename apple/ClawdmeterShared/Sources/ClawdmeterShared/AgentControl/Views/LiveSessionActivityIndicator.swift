#if canImport(SwiftUI)
import Foundation
import SwiftUI

/// "Session is still working" footer for the live chat list. Shows when
/// the session's JSONL has been touched within the activity window —
/// drives off `SessionChatStore.snapshot.lastEventAt` on Mac and
/// `iOSChatStore.snapshot.lastEventAt` on iOS.
///
/// Two provider variants:
///   - **Claude**: terra-cotta accent (`#D97757`) with the Anthropic-
///     style asterisk rotating like the brand mark.
///   - **Codex**: codex-blue accent (`#5C9DFF`) with a pulsing sparkle.
///
/// The label is `<elapsed> · thinking…` where `<elapsed>` includes
/// hundredths of a second. Caller hands in the start moment; we don't fix
/// it to the most recent event so the timer keeps climbing across rapid bursts.
/// The user feedback that triggered this: "there's no way to know that
/// the session is still moving forward and claude/codex is working."
public struct LiveSessionActivityIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Provider drives the accent + symbol.
    public let agent: AgentKind
    /// Most-recent observed event on the JSONL. nil → hide.
    public let lastEventAt: Date?
    /// When the agent started this turn — drives the elapsed counter.
    /// Falls back to `lastEventAt` if the caller doesn't know.
    public let activityStartedAt: Date?
    /// How long after `lastEventAt` we consider the agent still working.
    /// 30 seconds matches the Mac chat-thread "thinking" window
    /// documented in `SessionChatStore.lastEventAt`.
    public let activityWindow: TimeInterval

    public init(
        agent: AgentKind,
        lastEventAt: Date?,
        activityStartedAt: Date? = nil,
        activityWindow: TimeInterval = 30
    ) {
        self.agent = agent
        self.lastEventAt = lastEventAt
        self.activityStartedAt = activityStartedAt
        self.activityWindow = activityWindow
    }

    public var body: some View {
        // v0.30.x (PR A1): replaced the `Timer.scheduledTimer @ 20Hz +
        // @State now = Date()` pattern with `TimelineView(.periodic)`.
        // The old timer fired 20× per second per visible chat and mutated
        // `@State now` on every tick, invalidating the pill body + the
        // surrounding view chain. `TimelineView` drives `context.date`
        // without `@State` mutation, so SwiftUI only re-renders the body
        // closure (Capsule + Material + Text) on each tick, not the whole
        // view tree. Reduce-Motion downgrades to 1Hz; otherwise 0.2s (5Hz)
        // since the elapsed string only displays one decimal anyway.
        TimelineView(.periodic(from: .now, by: reduceMotion ? 1.0 : 0.2)) { context in
            let now = context.date
            let active = isActive(at: now)
            Group {
                if active {
                    HStack(spacing: 8) {
                        spinner
                        Text("\(elapsedString(at: now)) · thinking…")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.thinMaterial, in: Capsule())
                    .overlay(
                        Capsule().stroke(accent.opacity(0.25), lineWidth: 0.5)
                    )
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.95)))
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: active)
        }
    }

    // MARK: - Derived

    private func isActive(at now: Date) -> Bool {
        guard let lastEventAt else { return false }
        return now.timeIntervalSince(lastEventAt) < activityWindow
    }

    private func elapsedSeconds(at now: Date) -> TimeInterval {
        let start = activityStartedAt ?? lastEventAt ?? now
        return max(0, now.timeIntervalSince(start))
    }

    private func elapsedString(at now: Date) -> String {
        // v0.29.4: one decimal — pairs with the 0.2s TimelineView tick.
        let s = elapsedSeconds(at: now)
        if s < 60 { return String(format: "%.1fs", s) }
        let m = Int(s) / 60
        let r = s - Double(m * 60)
        return String(format: "%dm %.1fs", m, r)
    }

    private var accent: Color {
        switch agent {
        case .claude:
            // Anthropic terra-cotta — same #D97757 used by the gauge +
            // chat bubble + Live Activity indicator.
            return Color(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0)
        case .codex:
            // Codex blue — same #5C9DFF used in SessionsV2Theme.codexBlue.
            return Color(red: 0x5C / 255.0, green: 0x9D / 255.0, blue: 0xFF / 255.0)
        case .gemini:
            // Google blue — Antigravity / Gemini CLI's brand accent.
            // Used by the Gemini gauge, chat bubble + Live Activity indicator.
            return Color(red: 0x42 / 255.0, green: 0x85 / 255.0, blue: 0xF4 / 255.0)
        case .opencode:
            // OpenCode violet (#6B5DD3) — the brand accent for the
            // CLI's built-in TUI. Distinct from the blues so the live
            // indicator is visually separable on a multi-pane Mac
            // workspace.
            return Color(red: 0x6B / 255.0, green: 0x5D / 255.0, blue: 0xD3 / 255.0)
        case .cursor:
            return Color(red: 0x22 / 255.0, green: 0x22 / 255.0, blue: 0x22 / 255.0)
        case .unknown:
            // X3: neutral gray for forward-compat unknown kinds.
            return Color(red: 0x88 / 255.0, green: 0x88 / 255.0, blue: 0x88 / 255.0)
        }
    }

    @ViewBuilder
    private var spinner: some View {
        switch agent {
        case .claude:
            ClaudeAsteriskSpinner(color: accent, size: 14)
        case .codex:
            CodexPulseSpinner(color: accent, size: 14)
        case .gemini:
            // Reuse Claude's asterisk spinner — Gemini's brand mark is a
            // 4-pointed star which closely resembles the asterisk. Distinct
            // accent color keeps providers visually separable.
            ClaudeAsteriskSpinner(color: accent, size: 14)
        case .opencode:
            // PR #29: OpenCode TUI shows a rotating spinner during
            // tool calls. Reuse the Codex pulse spinner so the iOS
            // surface gets a "working" visual; the violet accent
            // disambiguates from the blue Codex one.
            CodexPulseSpinner(color: accent, size: 14)
        case .cursor:
            CodexPulseSpinner(color: accent, size: 14)
        case .unknown:
            // X3: reuse the asterisk spinner for unknown kinds. Pairs
            // with the neutral gray accent so it reads as "indeterminate
            // provider" rather than misclassifying.
            ClaudeAsteriskSpinner(color: accent, size: 14)
        }
    }

}

// MARK: - Spinners

/// 8-point asterisk that rotates 360° / 1.4s, mirroring the Anthropic
/// brand mark's idle animation.
private struct ClaudeAsteriskSpinner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let color: Color
    let size: CGFloat
    @State private var rotation: Double = 0

    var body: some View {
        Image(systemName: "asterisk")
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(color)
            .rotationEffect(.degrees(rotation))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
            .onChange(of: reduceMotion) { _, newValue in
                if newValue { rotation = 0 }
            }
    }
}

/// Three-dot pulse that sweeps left-to-right, the same shape Codex uses
/// in its CLI status line. SwiftUI primitive so we don't need a custom
/// glyph asset.
private struct CodexPulseSpinner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let color: Color
    let size: CGFloat
    @State private var phase: Double = 0

    var body: some View {
        HStack(spacing: size / 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(color)
                    .frame(width: size / 3, height: size / 3)
                    .opacity(opacity(forIndex: i))
            }
        }
        .frame(width: size, height: size)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
        .onChange(of: reduceMotion) { _, newValue in
            if newValue { phase = 0 }
        }
    }

    private func opacity(forIndex i: Int) -> Double {
        let stride = 0.33
        let p = (phase - stride * Double(i)).truncatingRemainder(dividingBy: 1.0)
        let positive = p < 0 ? p + 1 : p
        return 0.3 + 0.7 * (1 - positive)
    }
}
#endif

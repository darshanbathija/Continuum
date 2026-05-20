#if canImport(SwiftUI)
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
/// The label is `<elapsed> · thinking…` where `<elapsed>` ticks every
/// second. Caller hands in the start moment; we don't fix it to the
/// most recent event so the timer keeps climbing across rapid bursts.
/// The user feedback that triggered this: "there's no way to know that
/// the session is still moving forward and claude/codex is working."
public struct LiveSessionActivityIndicator: View {
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

    @State private var now: Date = Date()
    @State private var ticker: Timer?

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
        Group {
            if isActive {
                HStack(spacing: 8) {
                    spinner
                    Text("\(elapsedString) · thinking…")
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
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
                .onAppear { startTicker() }
                .onDisappear { stopTicker() }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isActive)
    }

    // MARK: - Derived

    private var isActive: Bool {
        guard let lastEventAt else { return false }
        return now.timeIntervalSince(lastEventAt) < activityWindow
    }

    private var elapsedSeconds: Int {
        let start = activityStartedAt ?? lastEventAt ?? now
        return max(0, Int(now.timeIntervalSince(start)))
    }

    private var elapsedString: String {
        let s = elapsedSeconds
        if s < 60 { return "\(s)s" }
        let m = s / 60
        let r = s % 60
        return "\(m)m \(r)s"
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
        }
    }

    // MARK: - Timer

    private func startTicker() {
        stopTicker()
        // 1Hz tick. Cheap; we're only invalidating one View on the chat
        // thread footer, not the whole list.
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in
                self.now = Date()
            }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }
}

// MARK: - Spinners

/// 8-point asterisk that rotates 360° / 1.4s, mirroring the Anthropic
/// brand mark's idle animation.
private struct ClaudeAsteriskSpinner: View {
    let color: Color
    let size: CGFloat
    @State private var rotation: Double = 0

    var body: some View {
        Image(systemName: "asterisk")
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(color)
            .rotationEffect(.degrees(rotation))
            .onAppear {
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
    }
}

/// Three-dot pulse that sweeps left-to-right, the same shape Codex uses
/// in its CLI status line. SwiftUI primitive so we don't need a custom
/// glyph asset.
private struct CodexPulseSpinner: View {
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
            withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
                phase = 1
            }
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

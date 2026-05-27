import SwiftUI
import ClawdmeterShared

/// Bottom-of-chat metadata strip that mirrors what Claude Code and Codex
/// show in their TUIs:
///
///     `* 11m 47s · 19.2k tokens · $0.42`     (Claude — pulsing asterisk)
///     `Thinking · 2m 14s · 8.4k tokens`      (Codex — fading "Thinking")
///
/// The animated indicator only pulses when the agent is actively working
/// (last JSONL event within the 60-second activity window). Past that
/// window the strip stays visible but the indicator becomes a static
/// "Idle" marker.
///
/// Token totals come from `SessionChatStore.snapshot.totalTokens` (Claude
/// assistant `message.usage` sums). Codex sessions show "—" for tokens
/// because the chat parser doesn't currently surface Codex's
/// `event_msg.token_count` events.
struct SessionActivityStrip: View {
    let session: AgentSession
    // A5 — split the chat-store dep into the two slices this strip
    // actually reads. liveStatusSlice drives the pulsing indicator
    // (lastEventAt → isActive); composerSlice drives the token + cost
    // labels (totals, modelHint). Transcript-only appends that carry
    // no token delta now only invalidate liveStatusSlice (for the
    // lastEventAt pulse), and the cost label's body stays put.
    @ObservedObject var liveStatusSlice: ChatLiveStatusSlice
    @ObservedObject var composerSlice: ChatComposerSlice

    init(session: AgentSession, chatStore: SessionChatStore) {
        self.session = session
        _liveStatusSlice = ObservedObject(wrappedValue: chatStore.liveStatusSlice)
        _composerSlice = ObservedObject(wrappedValue: chatStore.composerSlice)
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Drives a 1Hz re-render so the duration text updates live without
    /// the user having to scroll or type. SwiftUI's `Text(_, style: .timer)`
    /// could do this declaratively but doesn't support our custom
    /// `Xm Ys` format — explicit ticker keeps the format identical to
    /// the Claude TUI.
    @State private var now: Date = Date()
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// Window during which the agent counts as "thinking" — matches the
    /// existing 5-minute live-session window for repo discovery but
    /// tightened to 60s because we're showing live activity, not just
    /// recency.
    private static let activityWindow: TimeInterval = 60

    var body: some View {
        HStack(spacing: 8) {
            indicator
            Text(durationLabel)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            tokenLabel
            costLabel
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .onReceive(ticker) { stamp in now = stamp }
    }

    // MARK: - Indicator (per-agent style)

    @ViewBuilder
    private var indicator: some View {
        let active = isActive
        switch session.agent {
        case .claude:
            // Claude Code's TUI shows a pulsing asterisk (✻ / *) while
            // the agent processes. We use the same character set so the
            // affordance carries across surfaces.
            Text("✻")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(active ? claudeOrange : .secondary)
                .opacity(active ? animationOpacity : 0.5)
                .animation(
                    active
                        ? SessionsV2Theme.pulseAnimation(for: .claude, reduceMotion: reduceMotion)
                        : .default,
                    value: animationOpacity
                )
                .frame(width: 14, alignment: .leading)
        case .codex:
            // Codex shows the literal word "Thinking" in low-contrast
            // gray that fades in/out. Matches what the user sees in
            // the Codex Desktop app.
            Text(active ? "Thinking" : "Idle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .opacity(active ? animationOpacity : 0.5)
                .animation(
                    active
                        ? SessionsV2Theme.pulseAnimation(for: .codex, reduceMotion: reduceMotion)
                        : .default,
                    value: animationOpacity
                )
        case .gemini:
            // Reuse the Codex-style "Thinking" label; the Gemini UI
            // doesn't yet have its own pulsing motif and this keeps the
            // activity strip working until one ships.
            Text(active ? "Thinking" : "Idle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .opacity(active ? animationOpacity : 0.5)
                .animation(
                    active
                        ? SessionsV2Theme.pulseAnimation(for: .codex, reduceMotion: reduceMotion)
                        : .default,
                    value: animationOpacity
                )
        case .opencode:
            // PR #29: "Working" matches the OpenCode TUI's status copy.
            Text(active ? "Working" : "Idle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .opacity(active ? animationOpacity : 0.5)
                .animation(
                    active
                        ? SessionsV2Theme.pulseAnimation(for: .codex, reduceMotion: reduceMotion)
                        : .default,
                    value: animationOpacity
                )
        case .cursor:
            Text(active ? "Thinking" : "Idle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .opacity(active ? animationOpacity : 0.5)
                .animation(
                    active
                        ? SessionsV2Theme.pulseAnimation(for: .codex, reduceMotion: reduceMotion)
                        : .default,
                    value: animationOpacity
                )
        case .unknown:
            // X3: forward-compat unknown agent — neutral "Working" label.
            Text(active ? "Working" : "Idle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .opacity(active ? animationOpacity : 0.5)
                .animation(
                    active
                        ? SessionsV2Theme.pulseAnimation(for: .codex, reduceMotion: reduceMotion)
                        : .default,
                    value: animationOpacity
                )
        }
    }

    /// The animation drives between 0.4 and 1.0 so the indicator is
    /// always visible but visibly oscillates.
    @State private var animationOpacity: Double = 0.4
    private func startAnimation() {
        animationOpacity = isActive ? 1.0 : 0.5
    }

    // MARK: - Duration / tokens / cost labels

    private var durationLabel: String {
        let elapsed = max(0, now.timeIntervalSince(session.createdAt))
        return formatDuration(elapsed)
    }

    @ViewBuilder
    private var tokenLabel: some View {
        let total = composerSlice.totalTokens
        if total > 0 {
            Text("·")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Text(formatTokens(total))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        } else if session.agent == .codex {
            // No usage data available for Codex chat — hint that the
            // analytics tab covers it instead of leaving a gap.
            Text("·")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Text("tokens in Analytics")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var costLabel: some View {
        if let cost = estimateCost(), cost > 0 {
            Text("·")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Text(formatCost(cost))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers

    private var isActive: Bool {
        guard let stamp = liveStatusSlice.lastEventAt else { return false }
        return now.timeIntervalSince(stamp) < Self.activityWindow
    }

    private var claudeOrange: Color { SessionsV2Theme.accent }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let hr = total / 3600
        let mn = (total % 3600) / 60
        let sc = total % 60
        if hr > 0 { return String(format: "%dh %dm", hr, mn) }
        if mn > 0 { return String(format: "%dm %02ds", mn, sc) }
        return String(format: "%ds", sc)
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 {
            let m = Double(n) / 1_000_000
            return String(format: "%.1fM tokens", m)
        }
        if n >= 1_000 {
            let k = Double(n) / 1_000
            // Match the Claude TUI's "19.2k tokens" style.
            return String(format: "%.1fk tokens", k)
        }
        return "\(n) tokens"
    }

    /// Best-effort cost estimate using the embedded LiteLLM pricing
    /// snapshot. Returns nil for Codex sessions (no per-message usage
    /// to price), or when the model isn't in pricing.json.
    ///
    /// The four token categories are passed separately because they
    /// bill at vastly different rates: Sonnet cache_read is 10% of
    /// fresh input; Opus cache_creation is 125%. Conflating them into
    /// `inputTokens` undercounted Opus-4-7 sessions by ~80x before
    /// this fix.
    ///
    /// Model: the live session's `message.model` value as captured by
    /// the staging parser. Falls back to a sane Claude default only
    /// when no assistant message has been ingested yet.
    private func estimateCost() -> Decimal? {
        guard session.agent == .claude else { return nil }
        let totals = TokenTotals(
            inputTokens: composerSlice.totalInputTokens,
            outputTokens: composerSlice.totalOutputTokens,
            cacheCreationTokens: composerSlice.totalCacheCreationTokens,
            cacheReadTokens: composerSlice.totalCacheReadTokens,
            reasoningTokens: 0,
            costUSD: 0
        )
        let model = composerSlice.modelHint ?? "claude-sonnet-4-5"
        return Pricing.shared.cost(for: model, tokens: totals)
    }

    private func formatCost(_ cost: Decimal) -> String {
        // $0.42 for small, $12.34 for larger, $1.2k for absurd.
        let dbl = NSDecimalNumber(decimal: cost).doubleValue
        if dbl >= 1000 {
            return String(format: "$%.1fk", dbl / 1000)
        }
        if dbl >= 1 {
            return String(format: "$%.2f", dbl)
        }
        return String(format: "$%.3f", dbl)
    }
}

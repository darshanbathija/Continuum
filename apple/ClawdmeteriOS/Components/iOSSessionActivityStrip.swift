import SwiftUI
import ClawdmeterShared

/// iOS port of the Mac `SessionActivityStrip` — sits between the chat
/// content and the controls strip. Shows agent-state indicator (pulsing
/// terra-cotta `✻` for Claude, fading "Thinking" for Codex), session
/// duration, token totals, and a best-effort cost estimate.
///
/// Sessions v2 T39 from main-reconciliation gap analysis.
struct iOSSessionActivityStrip: View {
    let session: AgentSession
    @ObservedObject var chatStore: iOSChatStore

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulseToggle: Bool = false

    var body: some View {
        Group {
            if !idle {
                HStack(spacing: 10) {
                    indicator
                    VStack(alignment: .leading, spacing: 1) {
                        Text(stateLabel)
                            .font(.caption.weight(.semibold))
                        Text("\(durationLabel) · \(tokenLabel)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let cost = costLabel {
                        Text(cost)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(SessionsV2Theme.surfaceElev0)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilityLabel)
                .onAppear {
                    if !reduceMotion {
                        pulseToggle = true
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var indicator: some View {
        if session.agent == .claude {
            Text("✻")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(idle ? SessionsV2Theme.textTertiary : SessionsV2Theme.accent)
                .opacity(reduceMotion || idle ? 1.0 : (pulseToggle ? 1.0 : 0.4))
                .animation(
                    SessionsV2Theme.pulseAnimation(for: .claude, reduceMotion: reduceMotion),
                    value: pulseToggle
                )
        } else {
            Text("Thinking")
                .font(.caption.weight(.semibold))
                .foregroundStyle(idle ? SessionsV2Theme.textTertiary : SessionsV2Theme.codexBlue)
                .opacity(reduceMotion || idle ? 1.0 : (pulseToggle ? 1.0 : 0.5))
                .animation(
                    SessionsV2Theme.pulseAnimation(for: .codex, reduceMotion: reduceMotion),
                    value: pulseToggle
                )
        }
    }

    private var idle: Bool {
        guard let last = chatStore.snapshot.lastEventAt else { return true }
        return Date().timeIntervalSince(last) > 60
    }

    private var stateLabel: String {
        if idle { return "Idle" }
        return session.agent == .claude ? "Claude working…" : "Codex thinking…"
    }

    private var durationLabel: String {
        // v0.29.4: one decimal place — matches Mac LiveSessionActivityIndicator
        // and avoids fake-precision noise at sub-second refresh rates.
        let elapsed = max(0, Date().timeIntervalSince(session.createdAt))
        if elapsed < 60 { return String(format: "%.1fs", elapsed) }
        let mins = Int(elapsed) / 60
        let secs = elapsed - Double(mins * 60)
        return String(format: "%dm %.1fs", mins, secs)
    }

    private var tokenLabel: String {
        let total = chatStore.snapshot.totalInputTokens + chatStore.snapshot.totalOutputTokens
        if total == 0 { return "—" }
        if total < 1_000 { return "\(total) tok" }
        let k = Double(total) / 1_000.0
        return String(format: "%.1fk tok", k)
    }

    private var costLabel: String? {
        // Best-effort estimate. Claude only — Codex tokens aren't in chat JSONL
        // and come from the wham/usage endpoint instead (Phase 8 wiring).
        guard session.agent == .claude else { return nil }
        let input = Double(chatStore.snapshot.totalInputTokens)
        let output = Double(chatStore.snapshot.totalOutputTokens)
        let cost = (input * 3.0 + output * 15.0) / 1_000_000  // Sonnet 4.6 fallback rate
        guard cost > 0.001 else { return nil }
        return String(format: "$%.2f", cost)
    }

    private var accessibilityLabel: String {
        var parts: [String] = []
        parts.append(stateLabel)
        if !idle {
            parts.append("Duration \(durationLabel)")
            parts.append("Tokens \(tokenLabel)")
            if let cost = costLabel { parts.append("Cost \(cost)") }
        }
        return parts.joined(separator: ", ")
    }
}

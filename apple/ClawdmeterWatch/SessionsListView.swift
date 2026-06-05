import SwiftUI
import ClawdmeterShared

/// watchOS sessions list — Crown-scrollable, taps into session detail.
/// Reads `WatchPlanBridge.sessionsSummary` (populated from iPhone via
/// WCSession). Sessions v2 Phase 6.
struct SessionsListView: View {
    @ObservedObject var bridge: WatchPlanBridge

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if bridge.sessionsSummary.isEmpty {
                    Text("No active sessions")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.top, 20)
                } else {
                    ForEach(bridge.sessionsSummary) { summary in
                        NavigationLink(value: summary) {
                            sessionRow(summary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(rowAccessibilityLabel(summary))
                        .accessibilityHint("Double-tap to open this session.")
                    }
                }
            }
            .padding(.horizontal, 6)
        }
        .navigationTitle("Sessions")
        .navigationDestination(for: WatchSessionSummary.self) { summary in
            WatchSessionDetailView(summary: summary, bridge: bridge)
        }
    }

    @ViewBuilder
    private func sessionRow(_ summary: WatchSessionSummary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                statusDot(summary)
                Text(summary.repoDisplayName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if summary.needsAttention {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(TahoeAccent.halo.base.color)
                        .font(.caption2)
                }
            }
            HStack(spacing: 4) {
                Text(summary.agent.rawValue.capitalized)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(summary.agent == .claude ? TahoeAccent.halo.base.color : TahoeProvider.codex.halo.color)
                if let model = summary.modelDisplay {
                    Text("· \(model)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if let goal = summary.goalSnippet {
                Text(goal)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(6)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }

    private func statusDot(_ summary: WatchSessionSummary) -> some View {
        Circle().fill(statusColor(summary.status)).frame(width: 6, height: 6)
    }

    private func statusColor(_ raw: String) -> Color {
        switch raw {
        case "running":  return ContinuumTokens.live
        case "planning": return ContinuumTokens.paused
        case "paused":   return ContinuumTokens.warn
        case "done":     return ContinuumTokens.live
        case "degraded": return ContinuumTokens.error
        default:         return ContinuumTokens.fg3
        }
    }

    private func rowAccessibilityLabel(_ summary: WatchSessionSummary) -> String {
        var parts = [
            summary.repoDisplayName,
            "agent \(summary.agent.rawValue)",
            "status \(summary.status)",
        ]
        if let model = summary.modelDisplay {
            parts.append("model \(model)")
        }
        if summary.needsAttention {
            parts.append("needs attention")
        }
        if let goal = summary.goalSnippet, !goal.isEmpty {
            parts.append("goal \(goal)")
        }
        return parts.joined(separator: ", ")
    }
}

/// Per-session detail view on watchOS — agent + model + status + actions
/// (Approve plan / Interrupt / Send voice reply). Sessions v2 Phase 6.
struct WatchSessionDetailView: View {
    let summary: WatchSessionSummary
    @ObservedObject var bridge: WatchPlanBridge
    @State private var dictation: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                header
                actionButtons
            }
            .padding(.horizontal, 6)
        }
        .navigationTitle(summary.repoDisplayName)
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(summary.agent.rawValue.capitalized)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(summary.agent == .claude ? TahoeAccent.halo.base.color : TahoeProvider.codex.halo.color)
                if let model = summary.modelDisplay {
                    Text(model)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(summary.status.capitalized)
                    .font(.caption2.weight(.medium))
            }
            if let goal = summary.goalSnippet {
                Text(goal)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var actionButtons: some View {
        VStack(spacing: 6) {
            if summary.needsAttention {
                Button {
                    bridge.approve(sessionId: summary.id)
                } label: {
                    Label("Approve plan", systemImage: "checkmark.seal.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(TahoeAccent.halo.base.color)
                .accessibilityLabel("Approve plan for \(summary.repoDisplayName)")
                .accessibilityHint("Tells the agent to start running the proposed plan.")
            }
            Button(role: .destructive) {
                bridge.interrupt(sessionId: summary.id)
            } label: {
                Label("Interrupt", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Interrupt session")
            .accessibilityHint("Stops the agent. Same as pressing escape on the Mac.")

            // Audit P2 fix: "Voice reply" was a dead button — the watch
            // sent the op via WCSession but iOS only logged it. Hide
            // the control entirely until the iPhone-side dictation flow
            // exists. Flip `Self.voiceReplyAvailable` to true (and
            // implement WatchPlanBridgeIOS.handleVoiceReply) to bring
            // it back.
            if Self.voiceReplyAvailable {
                Button {
                    bridge.requestVoiceReply(sessionId: summary.id)
                } label: {
                    Label("Voice reply", systemImage: "mic.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(TahoeProvider.codex.halo.color)
                .accessibilityLabel("Send a voice reply")
                .accessibilityHint("Records a short message and sends it to the agent.")
            }
        }
    }

    /// Feature flag for the not-yet-implemented voice-reply flow.
    private static let voiceReplyAvailable: Bool = false
}

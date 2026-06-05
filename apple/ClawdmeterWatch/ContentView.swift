import SwiftUI
import ClawdmeterShared

/// watchOS main view — tightly packed for the watch screen. One screen,
/// scrollable if needed. Uses a `TimelineView(.everyMinute)` so the
/// countdowns tick live on the wrist.
struct ContentView: View {
    @ObservedObject var model: WatchUsageModel
    /// Sessions v2 Phase 6: optional plan bridge so the main view can show
    /// a "Sessions" entry-point button when iPhone has pushed session data.
    var planBridge: WatchPlanBridge?

    init(model: WatchUsageModel, planBridge: WatchPlanBridge? = nil) {
        self.model = model
        self.planBridge = planBridge
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let usage = model.usage {
                    meter(usage: usage)
                } else if model.needsReauth {
                    reauthState
                } else if !model.hasAnyToken {
                    emptyState
                } else {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Connecting…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let codex = model.codexUsage {
                    Divider().padding(.top, 4)
                    smallMeter(
                        title: "Codex",
                        usage: codex,
                        // Tahoe 26: Codex's brand halo (OpenAI blue), via the
                        // shared TahoeProvider tokens.
                        tint: TahoeProvider.codex.halo.color
                    )
                }
                if let gemini = model.geminiUsage {
                    Divider().padding(.top, 4)
                    smallMeter(
                        title: "Antigravity",
                        usage: gemini,
                        // Tahoe 26: Antigravity brand halo (renamed from Gemini).
                        tint: TahoeProvider.gemini.halo.color
                    )
                }

                // Sessions v2 Phase 6: sessions list entry point.
                if let bridge = planBridge, !bridge.sessionsSummary.isEmpty {
                    NavigationLink {
                        SessionsListView(bridge: bridge)
                    } label: {
                        HStack {
                            Image(systemName: "list.bullet.rectangle")
                            Text("\(bridge.sessionsSummary.count) sessions")
                                .font(.caption.weight(.medium))
                            if bridge.sessionsSummary.contains(where: { $0.needsAttention }) {
                                Spacer()
                                Image(systemName: "exclamationmark.circle.fill")
                                    .foregroundStyle(TahoeAccent.halo.base.color)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }
            }
            .padding(.horizontal, 8)
        }
        .containerBackground(.fill.tertiary, for: .navigation)
        .navigationTitle("Continuum")
    }

    @ViewBuilder
    private func meter(usage: UsageData) -> some View {
        let sessionResetDate = Date(timeIntervalSince1970: TimeInterval(usage.sessionEpoch))
        let weeklyResetDate = Date(timeIntervalSince1970: TimeInterval(usage.weeklyEpoch))

        VStack(alignment: .leading, spacing: 6) {
            Text("Session")
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(usage.sessionPct)")
                    .font(.system(size: 38, weight: .bold))
                    .monospacedDigit()
                Text("%")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                (Text("Resets ") + Text(sessionResetDate, style: .relative))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            TahoeRailMeter(percent: Double(min(max(usage.sessionPct, 0), 100)), provider: .claude, height: 7)
        }
        .padding(.top, 4)

        Divider()

        VStack(alignment: .leading, spacing: 6) {
            Text("Weekly")
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(usage.weeklyPct)%")
                    .font(.system(size: 18, weight: .semibold))
                    .monospacedDigit()
                Spacer()
                (Text("Resets ") + Text(weeklyResetDate, style: .relative))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            TahoeRailMeter(percent: Double(min(max(usage.weeklyPct, 0), 100)), provider: .claude, height: 6, secondary: true)
        }

        if model.receivingFromPhone {
            Text("via iPhone")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
    }

    /// Compact secondary meter — single row, used by Codex + Gemini below
    /// the primary Claude meter. Gemini's cloudcode-pa quota doesn't
    /// surface a weekly window so the row stays single-line by design.
    @ViewBuilder
    private func smallMeter(title: String, usage: UsageData, tint: Color) -> some View {
        let resetDate = Date(timeIntervalSince1970: TimeInterval(usage.sessionEpoch))
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(usage.sessionPct)%")
                    .font(.system(size: 14, weight: .semibold))
                    .monospacedDigit()
                (Text("· ") + Text(resetDate, style: .relative))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            ProgressView(value: Double(min(max(usage.sessionPct, 0), 100)) / 100.0)
                .tint(tint)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Waiting for iPhone")
                .font(.headline)
            Text("Open Continuum on your iPhone. Once it has a token, it pushes here automatically.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var reauthState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Reconnect")
                .font(.headline)
            Text("Token expired. Re-authenticate on the iPhone or Mac.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    private var brand: Color { TahoeProvider.claude.dot }
}

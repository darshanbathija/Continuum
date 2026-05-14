import SwiftUI
import ClawdmeterShared

/// watchOS main view — tightly packed for the watch screen. One screen,
/// scrollable if needed. Uses a `TimelineView(.everyMinute)` so the
/// countdowns tick live on the wrist.
struct ContentView: View {
    @ObservedObject var model: WatchUsageModel

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
            }
            .padding(.horizontal, 8)
        }
        .containerBackground(.fill.tertiary, for: .navigation)
        .navigationTitle("Clawdmeter")
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
            ProgressView(value: Double(min(max(usage.sessionPct, 0), 100)) / 100.0)
                .tint(brand)
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
            ProgressView(value: Double(min(max(usage.weeklyPct, 0), 100)) / 100.0)
        }

        if model.receivingFromPhone {
            Text("via iPhone")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Waiting for iPhone")
                .font(.headline)
            Text("Open Clawdmeter on your iPhone. Once it has a token, it pushes here automatically.")
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

    private var brand: Color {
        Color(red: 0xd9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0)
    }
}

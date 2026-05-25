import WidgetKit
import SwiftUI
import ClawdmeterShared

/// watchOS complications. Plan D6: four families on Modular Ultra /
/// Infograph faces — `accessoryCircular`, `accessoryCorner`,
/// `accessoryRectangular`, `accessoryInline`.
///
/// All four families share one `Widget`/`TimelineProvider`; the view
/// switches on `widgetFamily` and renders the right thing.
@main
struct ClawdmeterWatchWidgetsBundle: WidgetBundle {
    var body: some Widget {
        ClaudeComplication()
        PlanWaitingComplication()
        // v0.6.0: Antigravity task headline. The complication file
        // shipped in v0.6.0 but the bundle registration was missed —
        // so the widget never appeared in the watch face picker. Fixed
        // alongside the v0.7.8 Codex task complication ship.
        AntigravityTaskComplication()
        // v0.7.8: Codex SDK in-progress todo on the wrist.
        CodexTaskComplication()
    }
}

// MARK: - Widget

struct ClaudeComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "ClawdmeterMeter.claude",
            provider: ClaudeTimeline()
        ) { entry in
            ClaudeView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Claude usage")
        .description("Current Claude Code session and weekly usage on your watch face.")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryCorner,
            .accessoryRectangular,
            .accessoryInline,
        ])
    }
}

// MARK: - Timeline

struct ClaudeEntry: TimelineEntry {
    let date: Date
    let snapshot: UsageStore.Snapshot?
}

struct ClaudeTimeline: TimelineProvider {
    func placeholder(in context: Context) -> ClaudeEntry {
        ClaudeEntry(date: .now, snapshot: nil)
    }
    func getSnapshot(in context: Context, completion: @escaping (ClaudeEntry) -> Void) {
        completion(currentEntry())
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<ClaudeEntry>) -> Void) {
        let entry = currentEntry()
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: .now)!
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
    private func currentEntry() -> ClaudeEntry {
        ClaudeEntry(date: .now, snapshot: UsageStore.read(providerID: "claude"))
    }
}

// MARK: - View

struct ClaudeView: View {
    let entry: ClaudeEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular:    circular
        case .accessoryCorner:      corner
        case .accessoryRectangular: rectangular
        case .accessoryInline:      inline
        default:                    circular
        }
    }

    // MARK: Circular — gauge with percentage

    @ViewBuilder
    private var circular: some View {
        if let snap = entry.snapshot {
            Gauge(value: Double(snap.usage.sessionPct), in: 0...100) {
                Text("Claude")
            } currentValueLabel: {
                Text("\(snap.usage.sessionPct)")
                    .monospacedDigit()
            }
            .gaugeStyle(.accessoryCircularCapacity)
        } else {
            Image(systemName: "wifi.exclamationmark")
        }
    }

    // MARK: Corner — corner gauge for Infograph

    @ViewBuilder
    private var corner: some View {
        if let snap = entry.snapshot {
            Text("\(snap.usage.sessionPct)%")
                .font(.system(.title3, weight: .bold))
                .monospacedDigit()
                .widgetCurvesContent()
                .widgetLabel {
                    Gauge(value: Double(snap.usage.sessionPct), in: 0...100) {
                        Text("Claude")
                    }
                    .gaugeStyle(.accessoryLinearCapacity)
                }
        } else {
            Image(systemName: "questionmark")
                .widgetLabel("Open app")
        }
    }

    // MARK: Rectangular — provider name + percent + countdown

    @ViewBuilder
    private var rectangular: some View {
        if let snap = entry.snapshot {
            let resetDate = Date(timeIntervalSince1970: TimeInterval(snap.usage.sessionEpoch))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Image(systemName: "burst")
                    Text("Claude")
                        .font(.headline)
                }
                Text("\(snap.usage.sessionPct)% used")
                    .font(.subheadline)
                (Text("Resets ") + Text(resetDate, style: .relative))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        } else {
            VStack(alignment: .leading) {
                Text("Continuum")
                    .font(.headline)
                Text("Open app")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Inline — single-line text

    @ViewBuilder
    private var inline: some View {
        if let snap = entry.snapshot {
            let resetDate = Date(timeIntervalSince1970: TimeInterval(snap.usage.sessionEpoch))
            Text("Claude \(snap.usage.sessionPct)% · resets ")
                + Text(resetDate, style: .relative)
        } else {
            Text("Continuum offline")
        }
    }
}

private extension View {
    /// No-op shim for older SDKs that don't have `widgetCurvesContent`.
    @ViewBuilder
    func widgetCurvesContent() -> some View {
        if #available(watchOS 10.0, *) {
            self
        } else {
            self
        }
    }
}

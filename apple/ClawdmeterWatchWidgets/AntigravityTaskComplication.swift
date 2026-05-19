// `.accessoryCorner` complication that shows the current Antigravity 2
// task's headline (first 18 chars). Read-only — toggling steps or
// approving plans isn't surfaced on the watch in v0.6.0 (defer per D6).
//
// Data flow:
//   Mac dashboard sees a brain dir update →
//   WatchPlanBridge encodes Payload (including currentTaskHeadline) →
//   WCSession.updateApplicationContext to paired Watch →
//   Watch app's WatchPlanBridge.swift writes to App Group UserDefaults →
//   WidgetCenter.reloadAllTimelines() →
//   This complication's getTimeline() reads the headline and renders.

import WidgetKit
import SwiftUI

/// Stores the truncated headline locally in App Group UserDefaults. The
/// receiver side of WatchPlanBridge writes here whenever a fresh payload
/// arrives over WCSession.
struct AntigravityTaskComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "Clawdmeter.antigravityTask",
            provider: AntigravityTaskTimeline()
        ) { entry in
            AntigravityTaskView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Antigravity Task")
        .description("Shows the headline of the active Antigravity agent task.")
        .supportedFamilies([.accessoryCorner])
    }
}

struct AntigravityTaskEntry: TimelineEntry {
    let date: Date
    /// Truncated headline (≤18 chars). nil when no active task.
    let headline: String?
}

struct AntigravityTaskTimeline: TimelineProvider {
    func placeholder(in context: Context) -> AntigravityTaskEntry {
        AntigravityTaskEntry(date: .now, headline: "—")
    }

    func getSnapshot(in context: Context, completion: @escaping (AntigravityTaskEntry) -> Void) {
        completion(readEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AntigravityTaskEntry>) -> Void) {
        // Manual reloads via WidgetCenter.reloadAllTimelines() from
        // WatchPlanBridge when a fresh payload arrives — passive timeline
        // refresh is hourly fallback.
        let entry = readEntry()
        let next = Date().addingTimeInterval(60 * 60)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func readEntry() -> AntigravityTaskEntry {
        let defaults = UserDefaults(suiteName: "group.76S62SDSD3.com.clawdmeter")
        let raw = defaults?.string(forKey: "clawdmeter.watch.currentTaskHeadline")
        return AntigravityTaskEntry(date: .now, headline: raw)
    }
}

struct AntigravityTaskView: View {
    let entry: AntigravityTaskEntry

    var body: some View {
        Image(systemName: "sparkle")
            .resizable()
            .scaledToFit()
            .frame(width: 14, height: 14)
            .widgetCurvesContent()
            .widgetLabel(label)
    }

    @ViewBuilder
    private var label: some View {
        if let headline = entry.headline, !headline.isEmpty {
            let truncated = headline.count > 18 ? String(headline.prefix(18)) : headline
            Text(truncated)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .lineLimit(1)
                .truncationMode(.tail)
        } else {
            Text("Idle")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }
}

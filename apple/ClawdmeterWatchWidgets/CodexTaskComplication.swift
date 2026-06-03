// v0.7.8 — `.accessoryCorner` complication that shows the current
// Codex SDK session's in-progress todo (first 18 chars). Mirror of
// AntigravityTaskComplication but reads the `codexCurrentTodo` App
// Group key written by WatchPlanBridge on each WCSession payload.
//
// Data flow:
//   Mac dashboard observes SessionChatStore.snapshot.codexTodos →
//   WatchPlanBridge.Payload.codexCurrentTodo gets the first in-progress
//   item's text (truncated) →
//   WCSession.updateApplicationContext to paired Watch →
//   Watch's WatchPlanBridge writes App Group UserDefaults →
//   WidgetCenter.reloadTimelines(ofKind: "Clawdmeter.codexTask") →
//   This timeline reads the key and renders.

import WidgetKit
import SwiftUI

struct CodexTaskComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "Clawdmeter.codexTask",
            provider: CodexTaskTimeline()
        ) { entry in
            CodexTaskView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Codex Task")
        .description("Shows the current in-progress todo from the Codex SDK observer.")
        .supportedFamilies([.accessoryCorner])
    }
}

struct CodexTaskEntry: TimelineEntry {
    let date: Date
    /// Truncated todo text (≤18 chars). nil when no active Codex SDK
    /// session, or no in-progress todo has been emitted yet.
    let headline: String?
}

struct CodexTaskTimeline: TimelineProvider {
    func placeholder(in context: Context) -> CodexTaskEntry {
        CodexTaskEntry(date: .now, headline: "—")
    }

    func getSnapshot(in context: Context, completion: @escaping (CodexTaskEntry) -> Void) {
        completion(readEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CodexTaskEntry>) -> Void) {
        // Manual reloads via WidgetCenter.reloadTimelines(ofKind:) from
        // WatchPlanBridge when a fresh codexCurrentTodo arrives — passive
        // timeline refresh is hourly fallback.
        let entry = readEntry()
        let next = Date().addingTimeInterval(60 * 60)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func readEntry() -> CodexTaskEntry {
        let defaults = UserDefaults(suiteName: "group.LRL8MRH6B4.com.continuum")
        let raw = defaults?.string(forKey: "clawdmeter.watch.codexCurrentTodo")
        return CodexTaskEntry(date: .now, headline: raw)
    }
}

struct CodexTaskView: View {
    let entry: CodexTaskEntry

    var body: some View {
        Image(systemName: "checklist")
            .resizable()
            .scaledToFit()
            .frame(width: 14, height: 14)
            .widgetCurvesContent()
            .widgetLabel(displayText)
    }

    private var displayText: String {
        if let headline = entry.headline, !headline.isEmpty {
            return headline.count > 18 ? String(headline.prefix(18)) : headline
        }
        return "Idle"
    }
}

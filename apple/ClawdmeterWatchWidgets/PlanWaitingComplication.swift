import WidgetKit
import SwiftUI
import ClawdmeterShared

/// `accessoryCircular` complication — D10 "plan-waiting" badge.
///
/// Reads the count of pending plan approvals from the App Group shared
/// with the Watch app. The Watch app updates that count via `WCSession`
/// from the iPhone (which gets it from the Mac daemon over Tailscale).
///
/// V1 scope: one family (`accessoryCircular`). Other three families are
/// post-v1 polish.
struct PlanWaitingComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "ClawdmeterMeter.planWaiting",
            provider: PlanWaitingTimeline()
        ) { entry in
            PlanWaitingView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Plans waiting")
        .description("Glance at how many AI agent plans are awaiting your approval.")
        .supportedFamilies([.accessoryCircular])
    }
}

struct PlanWaitingEntry: TimelineEntry {
    let date: Date
    let count: Int
    let goalPreview: String?
}

struct PlanWaitingTimeline: TimelineProvider {
    func placeholder(in context: Context) -> PlanWaitingEntry {
        PlanWaitingEntry(date: .now, count: 0, goalPreview: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (PlanWaitingEntry) -> Void) {
        completion(readEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PlanWaitingEntry>) -> Void) {
        let entry = readEntry()
        // Refresh every 30 minutes; WCSession from iPhone explicitly reloads
        // when an event arrives.
        let next = Date().addingTimeInterval(30 * 60)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func readEntry() -> PlanWaitingEntry {
        let defaults = UserDefaults(suiteName: "group.76S62SDSD3.com.clawdmeter")
        let count = defaults?.integer(forKey: "clawdmeter.watch.planWaitingCount") ?? 0
        let goalPreview = defaults?.string(forKey: "clawdmeter.watch.latestGoal")
        return PlanWaitingEntry(date: .now, count: count, goalPreview: goalPreview)
    }
}

struct PlanWaitingView: View {
    let entry: PlanWaitingEntry

    var body: some View {
        // Tahoe 26: Halo cyan accent (was terra-cotta).
        let accent = TahoeAccent.halo.base.color
        ZStack {
            if entry.count > 0 {
                Circle()
                    .strokeBorder(accent, lineWidth: 2)
                Text("\(entry.count)")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(accent)
            } else {
                Circle()
                    .strokeBorder(.secondary.opacity(0.4), lineWidth: 1)
                Image(systemName: "doc.text")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
        }
        .widgetURL(URL(string: "clawdmeter://approve")!)
    }
}

import WidgetKit
import SwiftUI
import ClawdmeterShared
#if canImport(ActivityKit)
import ActivityKit
#endif

/// iPhone widget bundle.
///
/// Per plan D6 we ship Lock-Screen widgets first (accessoryCircular and
/// accessoryRectangular), then the Home Screen + StandBy systemSmall /
/// systemMedium variants. All read from the App Group `UsageStore` that
/// the iPhone app's `UsageModel` writes on every poll.
@main
struct ClawdmeteriOSWidgetsBundle: WidgetBundle {
    var body: some Widget {
        ClaudeUsageWidget()
        SessionLiveActivityWidget()
        GeminiQuotaLiveActivityWidget()
    }
}

@available(iOSApplicationExtension 16.1, *)
struct GeminiQuotaLiveActivityWidget: Widget {
    /// Google blue — matches the iOS Live tab + Mac dashboard tint.
    private let tint = Color(red: 0x42/255, green: 0x85/255, blue: 0xF4/255)

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: GeminiQuotaLiveActivityAttributes.self) { context in
            // Lock Screen pill.
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .stroke(.secondary.opacity(0.18), lineWidth: 4)
                        .frame(width: 36, height: 36)
                    Circle()
                        .trim(from: 0, to: max(0.001, Double(context.state.sessionPct) / 100.0))
                        .stroke(tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 36, height: 36)
                    Text("\(context.state.sessionPct)")
                        .font(.system(size: 12, weight: .bold))
                        .monospacedDigit()
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text("Gemini")
                            .font(.headline)
                        if context.state.stale {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                    (Text("Resets ") + Text(context.state.resetDate, style: .relative))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
            }
            .containerBackground(.fill.tertiary, for: .widget)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text("Gemini")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tint)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.state.sessionPct)%")
                        .font(.title3.weight(.bold))
                        .monospacedDigit()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        (Text("Resets ") + Text(context.state.resetDate, style: .relative))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Spacer()
                        if context.state.stale {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                Text("Stale")
                            }
                            .font(.caption2)
                            .foregroundStyle(.orange)
                        }
                    }
                }
            } compactLeading: {
                // Compact pill: the "G" glyph.
                Text("G")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tint)
            } compactTrailing: {
                Text("\(context.state.sessionPct)%")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
            } minimal: {
                // Always-on dimmed glyph — single character only.
                Text("G")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tint)
            }
        }
    }
}

@available(iOSApplicationExtension 16.1, *)
struct SessionLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SessionLiveActivityAttributes.self) { context in
            HStack(spacing: 10) {
                Text(context.state.agentEmoji)
                    .font(.title3.weight(.bold))
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.state.headlineText)
                        .font(.headline)
                        .lineLimit(1)
                    Text(context.state.needsAttention ? "Needs attention" : context.state.latestState.capitalized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .containerBackground(.fill.tertiary, for: .widget)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(context.state.agentEmoji)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.headlineText).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.activeSessionCount.formatted())
                }
            } compactLeading: {
                Text(context.state.agentEmoji)
            } compactTrailing: {
                Text(context.state.activeSessionCount.formatted())
            } minimal: {
                Text(context.state.agentEmoji)
            }
        }
    }
}

// MARK: - Widget

struct ClaudeUsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "ClawdmeterMeter.claude",
            provider: ClaudeUsageTimeline()
        ) { entry in
            ClaudeUsageView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Claude usage")
        .description("Current session and weekly Claude Code usage at a glance.")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryRectangular,
            .systemSmall,
            .systemMedium,
        ])
    }
}

// MARK: - Timeline

struct ClaudeUsageEntry: TimelineEntry {
    let date: Date
    let snapshot: UsageStore.Snapshot?
}

struct ClaudeUsageTimeline: TimelineProvider {
    func placeholder(in context: Context) -> ClaudeUsageEntry {
        ClaudeUsageEntry(date: .now, snapshot: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (ClaudeUsageEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ClaudeUsageEntry>) -> Void) {
        // Refresh every 15 minutes. The host app also calls
        // `WidgetCenter.shared.reloadTimelines(ofKind:)` on every successful
        // poll, so this is just the worst-case fallback.
        let entry = currentEntry()
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: .now)!
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func currentEntry() -> ClaudeUsageEntry {
        ClaudeUsageEntry(
            date: .now,
            snapshot: UsageStore.read(providerID: "claude")
        )
    }
}

// MARK: - Views

struct ClaudeUsageView: View {
    let entry: ClaudeUsageEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            circular
        case .accessoryRectangular:
            rectangular
        case .systemSmall:
            small
        case .systemMedium:
            medium
        default:
            small
        }
    }

    // MARK: Lock-Screen circular

    @ViewBuilder
    private var circular: some View {
        if let snap = entry.snapshot {
            ZStack {
                Gauge(value: Double(snap.usage.sessionPct), in: 0...100) {
                    Text("Claude")
                } currentValueLabel: {
                    Text("\(snap.usage.sessionPct)")
                        .font(.system(size: 14, weight: .bold))
                        .monospacedDigit()
                }
                .gaugeStyle(.accessoryCircularCapacity)
            }
        } else {
            ZStack {
                Image(systemName: "wifi.exclamationmark")
            }
        }
    }

    // MARK: Lock-Screen rectangular

    @ViewBuilder
    private var rectangular: some View {
        if let snap = entry.snapshot {
            let resetDate = Date(timeIntervalSince1970: TimeInterval(snap.usage.sessionEpoch))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
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
            VStack(alignment: .leading, spacing: 4) {
                Text("Clawdmeter")
                    .font(.headline)
                Text("Open the app")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Home Screen small

    @ViewBuilder
    private var small: some View {
        if let snap = entry.snapshot {
            let resetDate = Date(timeIntervalSince1970: TimeInterval(snap.usage.sessionEpoch))
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "burst")
                        .foregroundStyle(brand)
                    Text("Claude")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                Spacer(minLength: 0)
                ring(percent: snap.usage.sessionPct, size: 70)
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
                (Text("Resets ") + Text(resetDate, style: .relative))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        } else {
            emptyState
        }
    }

    // MARK: Home Screen medium

    @ViewBuilder
    private var medium: some View {
        if let snap = entry.snapshot {
            HStack(spacing: 18) {
                ring(percent: snap.usage.sessionPct, size: 80)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "burst")
                            .foregroundStyle(brand)
                        Text("Claude")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    Text("Session")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    let sessionReset = Date(timeIntervalSince1970: TimeInterval(snap.usage.sessionEpoch))
                    (Text("\(snap.usage.sessionPct)%  ·  Resets ") + Text(sessionReset, style: .relative))
                        .font(.subheadline)
                        .monospacedDigit()
                    Text("Weekly \(snap.usage.weeklyPct)%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else {
            emptyState
        }
    }

    // MARK: - Building blocks

    private var brand: Color {
        Color(red: 0xd9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0)
    }

    private func ring(percent: Int, size: CGFloat) -> some View {
        let value = max(0.001, min(1.0, Double(percent) / 100.0))
        return ZStack {
            Circle()
                .stroke(.secondary.opacity(0.15), lineWidth: size * 0.10)
            Circle()
                .trim(from: 0, to: value)
                .stroke(brand, style: StrokeStyle(lineWidth: size * 0.10, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(percent)")
                    .font(.system(size: size * 0.32, weight: .bold))
                    .monospacedDigit()
                Text("%")
                    .font(.system(size: size * 0.14, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 4) {
            Text("Clawdmeter")
                .font(.headline)
            Text("Open the app to connect")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

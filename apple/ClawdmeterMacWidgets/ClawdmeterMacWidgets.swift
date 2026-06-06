import WidgetKit
import SwiftUI
import ClawdmeterShared

// MARK: - Bundle (multiple widget kinds)
//
// `Widget` requires a no-arg `init()`, so we can't parameterise a single
// widget type and re-use it for both providers. Instead, two thin wrapper
// types delegate to a shared `ProviderWidgetConfiguration` builder.

@main
struct ClawdmeterMacWidgetsBundle: WidgetBundle {
    var body: some Widget {
        ClaudeWidget()
        CodexWidget()
        CombinedWidget()
    }
}

// `configurationDisplayName` and `description` must receive a literal
// `LocalizedStringKey` — WidgetKit walks the value's interpolation segments
// at registration time and rejects any non-literal string with
// "Formatted text for `configurationDisplayName` is not supported".
// Even a precomputed `let s = "Claude usage"` triggers the formatted path
// when passed via the LocalizedStringKey overload. So each widget is its
// own type with literal modifiers.

struct ClaudeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "ClawdmeterMeter.claude",
            provider: SingleProviderTimeline(providerID: "claude", displayName: "Claude")
        ) { entry in
            ProviderWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Claude usage")
        .description("Current session and weekly usage for Claude.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct CodexWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "ClawdmeterMeter.codex",
            provider: SingleProviderTimeline(providerID: "codex", displayName: "Codex")
        ) { entry in
            ProviderWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Codex usage")
        .description("Current session and weekly usage for Codex.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Combined widget (Claude + Codex side by side)

struct CombinedWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "ClawdmeterMeter.combined",
            provider: CombinedTimeline()
        ) { entry in
            CombinedWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Continuum")
        .description("Side-by-side Claude and Codex usage.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

// MARK: - Timeline entries

struct SingleProviderEntry: TimelineEntry {
    let date: Date
    let snapshot: UsageStore.Snapshot?
    let providerID: String
    let displayName: String
}

struct CombinedEntry: TimelineEntry {
    let date: Date
    let snapshots: [UsageStore.Snapshot]
}

// MARK: - Timeline providers

struct SingleProviderTimeline: TimelineProvider {
    let providerID: String
    let displayName: String

    func placeholder(in context: Context) -> SingleProviderEntry {
        SingleProviderEntry(date: .now, snapshot: nil, providerID: providerID, displayName: displayName)
    }

    func getSnapshot(in context: Context, completion: @escaping (SingleProviderEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SingleProviderEntry>) -> Void) {
        // Widget tick cadence: refresh every 5 min. The menu bar app also calls
        // `WidgetCenter.shared.reloadTimelines(ofKind:)` on every successful
        // poll, so this is just a worst-case fallback when the app isn't
        // running. WidgetKit budget on macOS is generous (~40-50 reloads/day),
        // and 5 min × 24h ≈ 288 — but reloadTimelines doesn't count against
        // the budget the same way reloadAllTimelines does.
        let entry = currentEntry()
        let next = Calendar.current.date(byAdding: .minute, value: 5, to: .now)!
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func currentEntry() -> SingleProviderEntry {
        SingleProviderEntry(
            date: .now,
            snapshot: UsageStore.read(providerID: providerID),
            providerID: providerID,
            displayName: displayName
        )
    }
}

struct CombinedTimeline: TimelineProvider {
    func placeholder(in context: Context) -> CombinedEntry {
        CombinedEntry(date: .now, snapshots: [])
    }

    func getSnapshot(in context: Context, completion: @escaping (CombinedEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CombinedEntry>) -> Void) {
        let entry = currentEntry()
        let next = Calendar.current.date(byAdding: .minute, value: 5, to: .now)!
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func currentEntry() -> CombinedEntry {
        CombinedEntry(date: .now, snapshots: UsageStore.readAll())
    }
}

// MARK: - Views

struct ProviderWidgetView: View {
    let entry: SingleProviderEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .systemSmall:
            small
        case .systemMedium:
            medium
        default:
            small
        }
    }

    @ViewBuilder
    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                providerBadge(providerID: entry.providerID, size: 16)
                Text(entry.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            if let snapshot = entry.snapshot {
                MeterGauge(usage: snapshot.usage, size: 70)
                    .frame(maxWidth: .infinity)
            } else {
                emptyState
            }
        }
        .padding(8)
    }

    @ViewBuilder
    private var medium: some View {
        HStack(spacing: 14) {
            VStack(spacing: 6) {
                providerBadge(providerID: entry.providerID, size: 20)
                Text(entry.displayName)
                    .font(.system(size: 12, weight: .semibold))
            }
            if let snapshot = entry.snapshot {
                MeterGauge(usage: snapshot.usage, size: 90)
                MeterLabels(usage: snapshot.usage)
            } else {
                emptyState
            }
            Spacer(minLength: 0)
        }
        .padding(12)
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 4) {
            Text("—")
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(.tertiary)
            Text(ProviderEnablement.isEnabled(entry.providerID) ? "Open Continuum" : "Enable in Continuum → Providers")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct CombinedWidgetView: View {
    let entry: CombinedEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if entry.snapshots.isEmpty {
            VStack(spacing: 4) {
                Text("Clawdmeter")
                    .font(.system(size: 13, weight: .semibold))
                Text("Open the menu bar app to get started")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(12)
        } else if family == .systemLarge {
            VStack(spacing: 12) {
                ForEach(entry.snapshots, id: \.providerID) { snap in
                    ProviderRow(snapshot: snap)
                }
            }
            .padding(12)
        } else {
            // medium
            HStack(spacing: 0) {
                ForEach(Array(entry.snapshots.enumerated()), id: \.element.providerID) { (i, snap) in
                    if i > 0 { Divider() }
                    VStack(spacing: 6) {
                        HStack(spacing: 4) {
                            providerBadge(providerID: snap.providerID, size: 14)
                            Text(snap.displayName)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        MeterGauge(usage: snap.usage, size: 64)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(8)
        }
    }
}

private struct ProviderRow: View {
    let snapshot: UsageStore.Snapshot

    var body: some View {
        HStack(spacing: 14) {
            VStack(spacing: 4) {
                providerBadge(providerID: snapshot.providerID, size: 22)
                Text(snapshot.displayName)
                    .font(.system(size: 12, weight: .semibold))
            }
            .frame(width: 70)

            MeterGauge(usage: snapshot.usage, size: 72)

            MeterLabels(usage: snapshot.usage)

            Spacer(minLength: 0)
        }
    }
}

// MARK: - Gauge primitive (ring + numeral, reused across families)

struct MeterGauge: View {
    let usage: UsageData
    let size: CGFloat

    private var displayedPercent: Int {
        usage.status == .notStarted ? 0 : usage.sessionPct
    }

    // Rail meter (the signature) — big SF Pro Rounded % over the Claude rail.
    var body: some View {
        VStack(alignment: .leading, spacing: size * 0.10) {
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                if usage.status == .notStarted {
                    Text("—")
                        .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
                        .foregroundStyle(ContinuumTokens.fg3)
                } else {
                    Text("\(usage.sessionPct)")
                        .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(ContinuumTokens.metricColor(percent: Double(usage.sessionPct)))
                    Text("%")
                        .font(.system(size: size * 0.18, weight: .semibold))
                        .foregroundStyle(ContinuumTokens.fg3)
                }
            }
            TahoeRailMeter(percent: Double(displayedPercent), provider: .claude, height: max(6, size * 0.09))
        }
        .frame(width: size, alignment: .leading)
    }
}

// MARK: - Side labels (countdown + weekly summary)

struct MeterLabels: View {
    let usage: UsageData

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if usage.status == .notStarted {
                Text("Not started")
                    .font(.system(size: 13, weight: .semibold))
                Text("Starts on next use")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                let resetDate = Date(timeIntervalSince1970: TimeInterval(usage.sessionEpoch))
                Text("Session")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("Resets \(resetDate, style: .relative)")
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
            }
            let weeklyDate = Date(timeIntervalSince1970: TimeInterval(usage.weeklyEpoch))
            Text("Weekly \(usage.weeklyPct)%")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            Text("Resets \(weeklyDate, style: .relative)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

// MARK: - Provider badge (asset lookup — falls back to text if missing)

@ViewBuilder
private func providerBadge(providerID: String, size: CGFloat) -> some View {
    let assetName: String = {
        switch providerID {
        case "claude": return "ClaudeLogo"
        case "codex":  return "CodexLogo"
        case "gemini": return "GeminiLogo"
        default:       return "ClaudeLogo"
        }
    }()
    if let nsImage = NSImage(named: assetName) {
        Image(nsImage: nsImage)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
    } else {
        Text(providerID.prefix(1).uppercased())
            .font(.system(size: size * 0.7, weight: .bold))
            .frame(width: size, height: size)
            .background(Circle().fill(.secondary.opacity(0.2)))
    }
}

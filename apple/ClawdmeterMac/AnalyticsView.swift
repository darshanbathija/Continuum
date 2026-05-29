import SwiftUI
import ClawdmeterShared

/// Token-analytics row on the macOS dashboard. Shown beneath the existing
/// Claude + Codex provider columns. Plan A1: always-visible, no navigation.
///
/// DEAD as of the Tahoe redesign: zero callsites (its old host
/// `DashboardView` no longer exists). The Usage tab now routes through
/// `MacRootView` → `Tahoe/MacUsageView`, which is the canonical, live
/// analytics surface — land analytics fixes there, not here. Kept (not
/// deleted) pending a separate decision on removing this orphan + the
/// shared Analytics/Views consumers.
@available(macOS 13, *)
struct AnalyticsView: View {

    // C2 — was `@ObservedObject` pre-C2. With `UsageHistoryStore`
    // now `@Observable`, `@Bindable` is the `@Observable` analogue
    // that gives us `$store.activeWindow`-style two-way bindings
    // (used by the Picker below). Reads outside the Picker still
    // get per-keypath tracking via SwiftUI's
    // `withObservationTracking`.
    @Bindable var store: UsageHistoryStore
    @Environment(\.colorScheme) private var colorScheme

    /// Per-section window for the by-repo list. Independent of `store.activeWindow`
    /// (which drives the totals grid + chart) per user feedback after V1 ship.
    @State private var repoWindow: UsageHistorySnapshot.Window = .past30d

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            if let snapshot = store.snapshot {
                AnalyticsTotalsGrid(snapshot: snapshot)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // v0.5.6: removed the `!= .allTime` gate. The chart's
                // `.allTime` branch (in `AnalyticsDailyChart`) walks the
                // union of activity days ascending and zero-fills gaps —
                // it always had the right behavior, but the gate hid it
                // for the "All time" window. User feedback flagged the
                // missing chart on the All-time filter.
                AnalyticsDailyChart(
                    snapshot: snapshot,
                    window: store.activeWindow,
                    providerFilter: .both
                )

                repoSection(snapshot: snapshot)

                footer(snapshot: snapshot)
            } else {
                loadingSkeleton
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(panelBackground)
    }

    // MARK: - Header (title + filter chips + refresh)

    private var header: some View {
        HStack(spacing: 12) {
            Text("Token usage")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(primaryText)

            Spacer()

            // Segmented window picker, same shape as the by-repo section
            // below — visually consistent across the whole analytics row.
            Picker("Window", selection: $store.activeWindow) {
                ForEach(UsageHistorySnapshot.Window.allCases, id: \.self) { w in
                    Text(w.label).tag(w)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .frame(maxWidth: 320)
            .labelsHidden()

            if let updatedAt = store.snapshot?.computedAt {
                (Text("Updated ") + Text(updatedAt, style: .relative))
                    .font(.system(size: 11))
                    .foregroundStyle(secondaryText)
                    .monospacedDigit()
            }

            Button(action: { store.forceRefresh() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(primaryText)
                    .frame(width: 24, height: 24)
                    .background(buttonFill)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Refresh analytics")
        }
    }

    // MARK: - By-repo section (window picker scoped to this section)

    private func repoSection(snapshot: UsageHistorySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("By repo")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(primaryText)
                Spacer()
                Picker("Window", selection: $repoWindow) {
                    ForEach(UsageHistorySnapshot.Window.allCases, id: \.self) { w in
                        Text(w.label).tag(w)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .frame(maxWidth: 280)
                .labelsHidden()
            }
            AnalyticsRepoList(
                snapshot: snapshot,
                window: repoWindow,
                providerFilter: .both
            )
        }
    }

    // MARK: - Footer

    private func footer(snapshot: UsageHistorySnapshot) -> some View {
        let claudeFiles = snapshot.sessionCount  // rough; close enough for the caption
        return HStack {
            Text("Indexed \(claudeFiles) sessions")
                .font(.system(size: 11))
                .foregroundStyle(secondaryText)
                .monospacedDigit()
            Spacer()
            if store.loading {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Skeleton

    private var loadingSkeleton: some View {
        VStack(alignment: .leading, spacing: 14) {
            ProgressView()
                .progressViewStyle(.linear)
                .tint(.secondary)
            Text("Indexing usage history…")
                .font(.system(size: 13))
                .foregroundStyle(secondaryText)
            AnalyticsTotalsGrid(snapshot: .empty, isLoading: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Theme

    private var primaryText: Color {
        colorScheme == .dark ? .white : .black
    }
    private var secondaryText: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.55)
            : Color.black.opacity(0.55)
    }
    private var panelBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.07, green: 0.07, blue: 0.07)
            : Color(red: 0.93, green: 0.93, blue: 0.93)
    }
    private var buttonFill: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.10)
            : Color.white
    }
}

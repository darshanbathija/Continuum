import SwiftUI
import ClawdmeterShared

/// Token-analytics row on the macOS dashboard. Shown beneath the existing
/// Claude + Codex provider columns. Plan A1: always-visible, no navigation.
@available(macOS 13, *)
struct AnalyticsView: View {

    @ObservedObject var store: UsageHistoryStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            if let snapshot = store.snapshot {
                AnalyticsTotalsGrid(snapshot: snapshot)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if store.activeWindow != .allTime {
                    AnalyticsDailyChart(
                        snapshot: snapshot,
                        window: store.activeWindow,
                        providerFilter: store.providerFilter
                    )
                }

                AnalyticsRepoList(
                    snapshot: snapshot,
                    window: store.activeWindow,
                    providerFilter: store.providerFilter
                )

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
        HStack(spacing: 10) {
            Text("Token usage")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(primaryText)

            Spacer()

            Picker("Provider", selection: $store.providerFilter) {
                ForEach(UsageHistoryStore.ProviderFilter.allCases, id: \.self) { f in
                    Text(f.label).tag(f)
                }
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(maxWidth: 110)

            Picker("Window", selection: $store.activeWindow) {
                ForEach(UsageHistorySnapshot.Window.allCases, id: \.self) { w in
                    Text(w.label).tag(w)
                }
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(maxWidth: 130)

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

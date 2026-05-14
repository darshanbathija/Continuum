import SwiftUI
import ClawdmeterShared

/// iOS analytics tab. Plan A2 + A18: ships in V1 regardless of paid-dev
/// status; reads from the iCloud-KV-mirrored snapshot. Three empty states
/// (no entitlement / no snapshot yet / loaded).
@available(iOS 16, *)
struct iOSAnalyticsView: View {
    @ObservedObject var model: UsageModel

    @State private var activeWindow: UsageHistorySnapshot.Window = .past30d
    @State private var providerFilter: UsageHistoryStore.ProviderFilter = .both

    private var iCloudAvailable: Bool {
        UsageCloudMirror.shared.isICloudAvailable
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let snap = model.analyticsSnapshot {
                        controls
                        AnalyticsTotalsGrid(snapshot: snap)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)

                        if activeWindow != .allTime {
                            AnalyticsDailyChart(
                                snapshot: snap,
                                window: activeWindow,
                                providerFilter: providerFilter
                            )
                            .padding(.horizontal, 4)
                        }

                        AnalyticsRepoList(
                            snapshot: snap,
                            window: activeWindow,
                            providerFilter: providerFilter
                        )
                        .padding(.horizontal, 4)

                        (Text("Updated ") + Text(snap.computedAt, style: .relative))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .padding(.horizontal, 4)
                    } else if iCloudAvailable {
                        waitingForMacCard
                    } else {
                        iCloudUnavailableCard
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Analytics")
            .navigationBarTitleDisplayMode(.large)
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack {
            Picker("Provider", selection: $providerFilter) {
                ForEach(UsageHistoryStore.ProviderFilter.allCases, id: \.self) { f in
                    Text(f.label).tag(f)
                }
            }
            .pickerStyle(.segmented)

            Picker("Window", selection: $activeWindow) {
                ForEach(UsageHistorySnapshot.Window.allCases, id: \.self) { w in
                    Text(w.label).tag(w)
                }
            }
            .pickerStyle(.menu)
        }
    }

    // MARK: - Empty states

    private var waitingForMacCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "macbook.and.iphone")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
            Text("Waiting for Mac sync")
                .font(.system(size: 17, weight: .semibold))
            Text("Run Clawdmeter on your Mac to populate the analytics here. The numbers sync via iCloud.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var iCloudUnavailableCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "icloud.slash")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
            Text("iCloud not enabled")
                .font(.system(size: 17, weight: .semibold))
            Text("Token analytics syncs from your Mac via iCloud. Enable the iCloud Key-Value capability on a paid Apple Developer account (or sign into iCloud on this device) to populate this tab.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

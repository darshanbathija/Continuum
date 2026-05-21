import SwiftUI
import ClawdmeterShared

/// iOS analytics tab. Plan A2 + A18: ships in V1 regardless of paid-dev
/// status; reads from the iCloud-KV-mirrored snapshot. Three empty states
/// (no entitlement / no snapshot yet / loaded).
@available(iOS 16, *)
struct iOSAnalyticsView: View {
    @ObservedObject var model: UsageModel
    @ObservedObject var agentClient: AgentControlClient
    /// Bound from root `ContentView` so the LiveGaugesHeader's auth cards
    /// (UnauthenticatedCard, ReauthCard) can pop the Settings sheet.
    @Binding var showingSettings: Bool

    @State private var activeWindow: UsageHistorySnapshot.Window = .past30d
    /// Per-section window for the by-repo list. Independent of `activeWindow`.
    @State private var repoWindow: UsageHistorySnapshot.Window = .past30d

    private var iCloudAvailable: Bool {
        UsageCloudMirror.shared.isICloudAvailable
    }

    /// True when the iPhone has scanned the pairing QR (host + token
    /// stored). The Tailscale path is the primary sync route now;
    /// iCloud is a fallback for users who happen to have it set up.
    private var isPairedWithMac: Bool {
        agentClient.host != nil && agentClient.token != nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // v0.8 nav reshuffle: gauges that used to live on a
                    // standalone "Live" tab now ride at the top of Analytics.
                    LiveGaugesHeader(
                        model: model,
                        agentClient: agentClient,
                        showingSettings: $showingSettings
                    )
                    .padding(.horizontal, 4)

                    if let snap = model.analyticsSnapshot {
                        // Segmented window picker — same shape as the
                        // by-repo section below.
                        Picker("Window", selection: $activeWindow) {
                            ForEach(UsageHistorySnapshot.Window.allCases, id: \.self) { w in
                                Text(w.label).tag(w)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 4)

                        AnalyticsTotalsGrid(snapshot: snap)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)

                        if activeWindow != .allTime {
                            AnalyticsDailyChart(
                                snapshot: snap,
                                window: activeWindow,
                                providerFilter: .both
                            )
                            .padding(.horizontal, 4)
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("By repo")
                                    .font(.system(size: 15, weight: .semibold))
                                Spacer()
                            }
                            Picker("Window", selection: $repoWindow) {
                                ForEach(UsageHistorySnapshot.Window.allCases, id: \.self) { w in
                                    Text(w.label).tag(w)
                                }
                            }
                            .pickerStyle(.segmented)
                            AnalyticsRepoList(
                                snapshot: snap,
                                window: repoWindow,
                                providerFilter: .both
                            )
                        }
                        .padding(.horizontal, 4)

                        (Text("Updated ") + Text(snap.computedAt, style: .relative))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .padding(.horizontal, 4)
                    } else if isPairedWithMac {
                        waitingForMacCard
                    } else if iCloudAvailable {
                        waitingForMacCard
                    } else {
                        notPairedCard
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Analytics")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { showingSettings = true }) {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
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
            Text("Open Clawdmeter on your Mac. Analytics syncs over Tailscale every 30 seconds.")
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

    private var notPairedCard: some View {
        VStack(spacing: 14) {
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
            Text("Not paired with a Mac")
                .font(.system(size: 17, weight: .semibold))
            Text("Open Clawdmeter on your Mac and tap **Sync with iPhone** in the header. Analytics syncs over Tailscale once paired — no iCloud required.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            PairingCTAButtons(client: agentClient)
                .padding(.horizontal, 24)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

import SwiftUI
import ClawdmeterShared

/// Two stacked provider sections: Claude (live-polled on iOS via the synced
/// Keychain token) and Codex (cloud-mirrored from the Mac via iCloud KV).
/// Each section mirrors the macOS dashboard's `ProviderColumn` shape.
struct ContentView: View {
    @ObservedObject var model: UsageModel
    @StateObject private var agentClient = AgentControlClient()
    @StateObject private var notifManager: iOSNotificationManager
    @State private var showingSettings: Bool = false

    init(model: UsageModel) {
        self.model = model
        let client = AgentControlClient()
        _agentClient = StateObject(wrappedValue: client)
        _notifManager = StateObject(wrappedValue: iOSNotificationManager(client: client))
        // Hand the same AgentControlClient to UsageModel so it can pull
        // live Codex usage + analytics from the Mac daemon over
        // Tailscale. Replaces the iCloud-KV path for users without a
        // paid Apple Developer entitlement (analytics + Codex tabs
        // previously showed "iCloud not enabled" stuck).
        model.wire(daemonClient: client)
    }

    var body: some View {
        TabView {
            liveTab
                .tabItem {
                    Label("Live", systemImage: "gauge.with.dots.needle.67percent")
                }

            iOSAnalyticsView(model: model, agentClient: agentClient)
                .tabItem {
                    Label("Analytics", systemImage: "chart.bar")
                }

            iOSSessionsView(client: agentClient)
                .tabItem {
                    Label("Sessions", systemImage: "rectangle.connected.to.line.below")
                }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(model: model)
        }
        .task {
            await notifManager.requestAuthorizationIfNeeded()
            notifManager.scheduleBackgroundRefresh()
        }
    }

    private var liveTab: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    if !model.tokenProvider.hasToken {
                        VStack(spacing: 14) {
                            ClaudeProviderHeader()
                            UnauthenticatedCard(showingSettings: $showingSettings, model: model)
                        }
                    } else if model.needsReauth {
                        VStack(spacing: 14) {
                            ClaudeProviderHeader()
                            ReauthCard(showingSettings: $showingSettings)
                        }
                    } else {
                        ClaudeSection(model: model)
                    }

                    Divider()
                        .padding(.horizontal, 4)

                    CodexSection(snapshot: model.codexSnapshot)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Clawdmeter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { showingSettings = true }) {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .refreshable { model.forcePoll() }
        }
    }
}

// MARK: - Claude (live-polled)

private struct ClaudeSection: View {
    @ObservedObject var model: UsageModel
    @AppStorage("clawdmeter.claude.advancedExpanded") private var advancedExpanded: Bool = false
    @AppStorage("clawdmeter.claude.autoRevive") private var autoReviveEnabled: Bool = false

    var body: some View {
        VStack(spacing: 14) {
            ClaudeProviderHeader()

            if let usage = model.usage {
                SessionCard(
                    title: "Current session",
                    percent: usage.sessionPct,
                    resetDate: Date(timeIntervalSince1970: TimeInterval(usage.sessionEpoch)),
                    notStarted: false,
                    tint: ClaudeBrand.color
                )
                WeeklyCard(
                    percent: usage.weeklyPct,
                    resetDate: Date(timeIntervalSince1970: TimeInterval(usage.weeklyEpoch))
                )
                advancedCard
                FooterRow(updatedAt: usage.updatedAt, onRefresh: { model.forcePoll() })
            } else {
                LoadingCard()
            }
        }
        .onChange(of: autoReviveEnabled) { _, newValue in
            model.setAutoReviveEnabled(newValue)
        }
        .onAppear {
            model.setAutoReviveEnabled(autoReviveEnabled)
        }
    }

    private var advancedCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: { withAnimation(.snappy) { advancedExpanded.toggle() } }) {
                HStack(spacing: 8) {
                    Image(systemName: advancedExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("Advanced")
                        .font(.system(size: 16, weight: .semibold))
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(16)

            if advancedExpanded {
                VStack(alignment: .leading, spacing: 14) {
                    Divider()
                    Toggle(isOn: $autoReviveEnabled) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Keep 5h timer ticking")
                                .font(.system(size: 14, weight: .medium))
                            Text("When the 5-hour window ends, send a 1-token 'Hi' to Claude Haiku 4.5 so a new window starts immediately.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .toggleStyle(.switch)

                    HStack(spacing: 8) {
                        autoReviveStatusView
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Spacer()
                        Button("Revive now") { model.reviveNow() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(!autoReviveEnabled)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private var autoReviveStatusView: some View {
        if !autoReviveEnabled {
            Text("Off — toggle on to keep the 5h window perpetual.")
        } else if let last = model.autoReviver.lastResult {
            switch last.outcome {
            case .fired:
                Text("Last revived ")
                    + Text(last.at, style: .relative)
                    + Text(" ago · \(model.autoReviver.fireCount) total")
            case .throttled:
                Text("Throttled ") + Text(last.at, style: .relative) + Text(" ago")
            case .noToken:
                Text("Skipped (no token) ") + Text(last.at, style: .relative) + Text(" ago")
            case .httpError(let code):
                Text("API error \(code) ") + Text(last.at, style: .relative) + Text(" ago")
            case .networkError:
                Text("Network error ") + Text(last.at, style: .relative) + Text(" ago")
            case .disabled:
                Text("Disabled")
            }
        } else {
            Text("Armed. Will fire when the next 5h window ends.")
        }
    }
}

// MARK: - Codex (cloud-mirrored)

private struct CodexSection: View {
    let snapshot: UsageStore.Snapshot?

    var body: some View {
        VStack(spacing: 14) {
            providerHeader

            if let snap = snapshot {
                let notStarted = snap.usage.status == .notStarted
                let usage = snap.usage
                SessionCard(
                    title: "Current session",
                    percent: notStarted ? 0 : usage.sessionPct,
                    resetDate: Date(timeIntervalSince1970: TimeInterval(usage.sessionEpoch)),
                    notStarted: notStarted,
                    tint: CodexBrand.color
                )
                WeeklyCard(
                    percent: usage.weeklyPct,
                    resetDate: Date(timeIntervalSince1970: TimeInterval(usage.weeklyEpoch))
                )
                HStack {
                    (Text("Synced from Mac ") + Text(snap.writtenAt, style: .relative) + Text(" ago"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer()
                }
                .padding(.horizontal, 4)
            } else {
                WaitingForMacCard()
            }
        }
    }

    private var providerHeader: some View {
        HStack(spacing: 10) {
            ProviderLogo(asset: "CodexLogo", size: 28)
            Text("Codex")
                .font(.system(size: 22, weight: .bold))
            Spacer()
        }
    }
}

// MARK: - Shared cards

private struct SessionCard: View {
    let title: String
    let percent: Int
    let resetDate: Date
    let notStarted: Bool
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3.bold())
            if notStarted {
                ProgressView(value: 0)
                HStack {
                    Text("Not started")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Starts on next use")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                ProgressView(value: max(0, min(1, Double(percent) / 100)))
                    .tint(tint)
                HStack {
                    Text("\(percent)% used")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    (Text("Resets ") + Text(resetDate, style: .relative))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct WeeklyCard: View {
    let percent: Int
    let resetDate: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Weekly limits")
                .font(.title3.bold())
            Text("All models")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ProgressView(value: max(0, min(1, Double(percent) / 100)))
            HStack {
                Text("\(percent)% used")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                (Text("Resets ") + Text(resetDate, style: .relative))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct FooterRow: View {
    let updatedAt: Date
    let onRefresh: () -> Void

    var body: some View {
        HStack {
            (Text("Last updated ") + Text(updatedAt, style: .relative) + Text(" ago"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .background(Color(.tertiarySystemGroupedBackground), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Refresh")
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }
}

private struct LoadingCard: View {
    var body: some View {
        HStack {
            ProgressView()
            Text("Connecting…").foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct WaitingForMacCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Waiting for the Mac app")
                .font(.headline)
            Text("Codex usage syncs from your paired Mac over Tailscale. Open Clawdmeter on the Mac and make sure ~/.codex/sessions/ has at least one rollout. If you haven't paired yet, scan the QR from Mac Settings → Sessions.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct UnauthenticatedCard: View {
    @Binding var showingSettings: Bool
    let model: UsageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Waiting for your Mac")
                .font(.title2.bold())
            Text("Open Clawdmeter on your Mac while signed into the same Apple ID — your Claude token will sync over iCloud Keychain and this screen will fill in automatically.")
                .font(.body)
                .foregroundStyle(.secondary)
            Button(action: { model.forcePoll() }) {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .padding(.top, 4)
            Button("Paste token instead") { showingSettings = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct ReauthCard: View {
    @Binding var showingSettings: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reconnect")
                .font(.title2.bold())
            Text("Your Anthropic token expired. Open Settings to paste a fresh one.")
                .font(.body)
                .foregroundStyle(.secondary)
            Button("Open Settings") { showingSettings = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Header + logo

private struct ClaudeProviderHeader: View {
    var body: some View {
        HStack(spacing: 10) {
            ProviderLogo(asset: "ClaudeLogo", size: 28)
            Text("Claude")
                .font(.system(size: 22, weight: .bold))
            Spacer()
        }
        .padding(.top, 4)
    }
}

private struct ProviderLogo: View {
    let asset: String
    let size: CGFloat

    var body: some View {
        if let img = UIImage(named: asset) {
            // Codex's asset is a black silhouette on transparent — switch
            // it to template rendering so SwiftUI tints it with the
            // current foreground style (adapts to light/dark mode).
            // Claude's burst keeps its terra-cotta color.
            let rendered = (asset == "CodexLogo")
                ? img.withRenderingMode(.alwaysTemplate)
                : img
            Image(uiImage: rendered)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .foregroundStyle(.primary)
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(.secondary.opacity(0.2))
                .frame(width: size, height: size)
        }
    }
}

private enum ClaudeBrand {
    static let color = Color(red: 0xd9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0)
}

private enum CodexBrand {
    static let color = Color.primary.opacity(0.85)
}

import SwiftUI
import ClawdmeterShared

/// Mirrors the macOS dashboard's `ProviderColumn`: provider title + logo,
/// Current session, Weekly limits, Advanced (collapsible), Last updated +
/// refresh. iPhone-specific styling — `Form`-like sections on a grouped
/// background.
struct ContentView: View {
    @ObservedObject var model: UsageModel
    @State private var showingSettings: Bool = false
    @AppStorage("clawdmeter.claude.advancedExpanded") private var advancedExpanded: Bool = false
    @AppStorage("clawdmeter.claude.autoRevive") private var autoReviveEnabled: Bool = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    providerHeader

                    if !model.tokenProvider.hasToken {
                        unauthenticatedCard
                    } else if model.needsReauth {
                        reauthCard
                    } else if let usage = model.usage {
                        currentSessionCard(usage: usage)
                        weeklyLimitsCard(usage: usage)
                        advancedCard
                        footerRow(usage: usage)
                    } else {
                        loadingCard
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
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
        .sheet(isPresented: $showingSettings) {
            SettingsView(model: model)
        }
        .onChange(of: autoReviveEnabled) { _, newValue in
            model.setAutoReviveEnabled(newValue)
        }
        .onAppear {
            model.setAutoReviveEnabled(autoReviveEnabled)
        }
    }

    // MARK: - Provider header

    private var providerHeader: some View {
        HStack(spacing: 10) {
            providerLogo(size: 28)
            Text("Claude")
                .font(.system(size: 22, weight: .bold))
            Spacer()
        }
        .padding(.top, 4)
    }

    // MARK: - Cards

    private func currentSessionCard(usage: UsageData) -> some View {
        let resetDate = Date(timeIntervalSince1970: TimeInterval(usage.sessionEpoch))
        return VStack(alignment: .leading, spacing: 12) {
            Text("Current session")
                .font(.title3.bold())
            ProgressView(value: progressValue(usage.sessionPct))
                .tint(brand)
            HStack {
                Text("\(usage.sessionPct)% used")
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

    private func weeklyLimitsCard(usage: UsageData) -> some View {
        let resetDate = Date(timeIntervalSince1970: TimeInterval(usage.weeklyEpoch))
        return VStack(alignment: .leading, spacing: 12) {
            Text("Weekly limits")
                .font(.title3.bold())
            Text("All models")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ProgressView(value: progressValue(usage.weeklyPct))
            HStack {
                Text("\(usage.weeklyPct)% used")
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

    // MARK: - Advanced

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

    // MARK: - Footer (Last updated + refresh)

    private func footerRow(usage: UsageData) -> some View {
        HStack {
            (Text("Last updated ") + Text(usage.updatedAt, style: .relative) + Text(" ago"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            Button(action: { model.forcePoll() }) {
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

    // MARK: - Empty states

    private var unauthenticatedCard: some View {
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

    private var reauthCard: some View {
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

    private var loadingCard: some View {
        HStack {
            ProgressView()
            Text("Connecting…").foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Helpers

    private func progressValue(_ pct: Int) -> Double {
        max(0, min(1, Double(pct) / 100))
    }

    @ViewBuilder
    private func providerLogo(size: CGFloat) -> some View {
        if let img = UIImage(named: "ClaudeLogo") {
            Image(uiImage: img)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(brand.opacity(0.2))
                .frame(width: size, height: size)
        }
    }

    private var brand: Color {
        Color(red: 0xd9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0)
    }
}

import SwiftUI
import ClawdmeterShared

/// Provider toggled on the Live tab. Tapping the header logo swaps which
/// provider's analytics fill the screen — no scrolling between them.
private enum LiveProvider: String, CaseIterable, Hashable {
    case claude
    case codex
}

/// Two stacked provider sections: Claude (live-polled on iOS via the synced
/// Keychain token) and Codex (cloud-mirrored from the Mac via iCloud KV).
/// Each section mirrors the macOS dashboard's `ProviderColumn` shape.
struct ContentView: View {
    @ObservedObject var model: UsageModel
    @StateObject private var agentClient = AgentControlClient()
    @StateObject private var notifManager: iOSNotificationManager
    @State private var showingSettings: Bool = false
    /// Persists across launches so a Codex-first user keeps landing on
    /// Codex. Default is Claude (matches the prior stacked layout's order).
    @AppStorage("clawdmeter.live.selectedProvider") private var selectedProviderRaw: String = LiveProvider.claude.rawValue
    /// Tracks horizontal swipe so we can derive a direction for the
    /// transition (swipe left → next provider slides in from the right).
    @State private var swipeDirection: Edge = .trailing

    init(model: UsageModel) {
        self.model = model
        let client = AgentControlClient()
        _agentClient = StateObject(wrappedValue: client)
        _notifManager = StateObject(wrappedValue: iOSNotificationManager(client: client))
        WatchPlanBridgeIOS.configure(client: client)
        // Hand the same AgentControlClient to UsageModel so it can pull
        // live Codex usage + analytics from the Mac daemon over
        // Tailscale. Replaces the iCloud-KV path for users without a
        // paid Apple Developer entitlement (analytics + Codex tabs
        // previously showed "iCloud not enabled" stuck).
        model.wire(daemonClient: client)
        // Phase 10: hand the client to LiveActivityCoordinator so it can
        // POST per-activity push tokens to the paired Mac as ActivityKit
        // produces them.
        LiveActivityCoordinator.shared.client = client
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

    private var selectedProvider: LiveProvider {
        LiveProvider(rawValue: selectedProviderRaw) ?? .claude
    }

    private var liveTab: some View {
        NavigationStack {
            VStack(spacing: 14) {
                ProviderToggleHeader(
                    selected: selectedProvider,
                    onPick: { picked in pickProvider(picked) }
                )
                .padding(.horizontal, 16)
                .padding(.top, 8)

                ScrollView {
                    Group {
                        switch selectedProvider {
                        case .claude: claudePane
                        case .codex:  codexPane
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 32)
                    .id(selectedProvider)
                    .transition(.asymmetric(
                        insertion: .move(edge: swipeDirection).combined(with: .opacity),
                        removal: .move(edge: swipeDirection == .leading ? .trailing : .leading).combined(with: .opacity)
                    ))
                }
                .scrollIndicators(.hidden)
                .refreshable { model.forcePoll() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
            // Horizontal swipe between providers — power-user shortcut
            // alongside tapping the logo. Drag threshold matches iOS's
            // standard "page swipe" feel.
            .gesture(
                DragGesture(minimumDistance: 30)
                    .onEnded { value in
                        let horizontal = value.translation.width
                        let vertical = abs(value.translation.height)
                        guard abs(horizontal) > 50, abs(horizontal) > vertical else { return }
                        toggleProvider(direction: horizontal < 0 ? .leading : .trailing)
                    }
            )
        }
    }

    /// Toggle between Claude and Codex. `direction` controls which edge
    /// the new content slides in from (`leading` = came from the right,
    /// `trailing` = came from the left). Called by the horizontal swipe
    /// gesture; the logo buttons call `pickProvider(_:)` directly.
    private func toggleProvider(direction: Edge = .trailing) {
        swipeDirection = direction
        let next: LiveProvider = (selectedProvider == .claude) ? .codex : .claude
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            selectedProviderRaw = next.rawValue
        }
    }

    /// Direct-pick a specific provider from the header's logo buttons.
    /// No-op when the user taps the already-selected logo. Slide
    /// direction matches the physical side the picked logo sits on —
    /// Claude (left) → slides in from the leading edge; Codex (right)
    /// → slides in from the trailing edge.
    private func pickProvider(_ provider: LiveProvider) {
        guard provider != selectedProvider else { return }
        swipeDirection = (provider == .claude) ? .leading : .trailing
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            selectedProviderRaw = provider.rawValue
        }
    }

    @ViewBuilder
    private var claudePane: some View {
        if !model.tokenProvider.hasToken {
            UnauthenticatedCard(showingSettings: $showingSettings, model: model)
        } else if model.needsReauth {
            ReauthCard(showingSettings: $showingSettings)
        } else {
            ClaudeSection(model: model)
        }
    }

    @ViewBuilder
    private var codexPane: some View {
        CodexSection(snapshot: model.codexSnapshot, agentClient: agentClient)
    }
}

// MARK: - Claude (live-polled)

private struct ClaudeSection: View {
    @ObservedObject var model: UsageModel
    @AppStorage("clawdmeter.claude.advancedExpanded") private var advancedExpanded: Bool = false
    @AppStorage("clawdmeter.claude.autoRevive") private var autoReviveEnabled: Bool = false

    var body: some View {
        VStack(spacing: 14) {
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
    @ObservedObject var agentClient: AgentControlClient

    var body: some View {
        VStack(spacing: 14) {
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
                WaitingForMacCard(agentClient: agentClient)
            }
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
    @ObservedObject var agentClient: AgentControlClient

    /// True when the iPhone already has host + token. In that case the
    /// problem is just "no rollouts yet", not "not paired" — keep the
    /// CTA hidden so the message reads honestly.
    private var isPairedWithMac: Bool {
        agentClient.host != nil && agentClient.token != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isPairedWithMac ? "Waiting for the Mac app" : "Not paired with a Mac")
                .font(.headline)
            Text(isPairedWithMac
                ? "Codex usage syncs from your paired Mac over Tailscale. Open Clawdmeter on the Mac and make sure `~/.codex/sessions/` has at least one rollout."
                : "Codex usage syncs from your paired Mac over Tailscale. Tap **Sync with iPhone** on the Mac, then scan the QR or paste the URL below.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !isPairedWithMac {
                PairingCTAButtons(client: agentClient, compact: true)
                    .padding(.top, 2)
            }
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

/// Provider toggle as a logo segmented control. Both Claude and Codex
/// logos render side-by-side at the top of the Live tab. Tapping a logo
/// switches to that provider; the active one is full-color + larger
/// with a name underneath, the inactive one is dimmed + smaller. Direct
/// affordance — no "swap" icon, no chevrons, the logos themselves are
/// the control.
private struct ProviderToggleHeader: View {
    let selected: LiveProvider
    /// Called when the user taps a specific provider's logo. The caller
    /// derives a slide direction from the picked side (left = leading
    /// edge, right = trailing edge).
    let onPick: (LiveProvider) -> Void

    var body: some View {
        HStack(spacing: 0) {
            providerButton(.claude)
            providerButton(.codex)
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
    }

    @ViewBuilder
    private func providerButton(_ provider: LiveProvider) -> some View {
        let isActive = (selected == provider)
        Button(action: { onPick(provider) }) {
            VStack(spacing: 6) {
                ProviderLogo(asset: logoAsset(for: provider), size: isActive ? 48 : 32)
                    .opacity(isActive ? 1.0 : 0.35)
                    .scaleEffect(isActive ? 1.0 : 0.92)
                Text(label(for: provider))
                    .font(.system(size: isActive ? 20 : 14, weight: isActive ? .bold : .medium))
                    .foregroundStyle(isActive ? .primary : .secondary)
                    .opacity(isActive ? 1.0 : 0.55)
                // Thin accent rule under the active logo — visual anchor
                // for "this is the one you're looking at".
                Rectangle()
                    .fill(isActive ? accent : Color.clear)
                    .frame(height: 2)
                    .frame(maxWidth: 40)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label(for: provider)) usage")
        .accessibilityAddTraits(isActive ? [.isSelected, .isButton] : .isButton)
        .accessibilityHint(isActive ? "Currently selected" : "Tap to switch")
    }

    private func logoAsset(for provider: LiveProvider) -> String {
        switch provider {
        case .claude: return "ClaudeLogo"
        case .codex:  return "CodexLogo"
        }
    }

    private func label(for provider: LiveProvider) -> String {
        switch provider {
        case .claude: return "Claude"
        case .codex:  return "Codex"
        }
    }

    private var accent: Color {
        Color(red: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0)
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

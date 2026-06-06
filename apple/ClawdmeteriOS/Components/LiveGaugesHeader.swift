import SwiftUI
import ClawdmeterShared

/// Provider toggled inside the Live gauges header. v0.8 nav reshuffle moved
/// these gauges out of the standalone Live tab and into the Analytics tab
/// header. Tapping the header logo swaps which provider's gauges fill the
/// section.
enum LiveProvider: String, CaseIterable, Hashable {
    case claude
    case codex
    case gemini
}

/// Embedded gauges header rendered at the top of the Analytics tab. Replaces
/// the standalone Live tab that v0.7.x carried. Owns the per-provider toggle,
/// swipe gesture, and per-provider section rendering.
///
/// Why embedded vs standalone: v0.8 Chat tab makes nav too crowded with a
/// dedicated Live tab. Folding the gauges into Analytics keeps the at-a-glance
/// surface available while freeing the tab slot for Chat.
struct LiveGaugesHeader: View {
    @ObservedObject var model: UsageModel
    @ObservedObject var agentClient: AgentControlClient
    @Binding var showingSettings: Bool

    @AppStorage("clawdmeter.live.selectedProvider") private var selectedProviderRaw: String = LiveProvider.claude.rawValue
    @State private var swipeDirection: Edge = .trailing

    private var selectedProvider: LiveProvider {
        let raw = LiveProvider(rawValue: selectedProviderRaw) ?? .claude
        if raw == .gemini && !agentClient.supportsGemini {
            return .claude
        }
        return raw
    }

    var body: some View {
        VStack(spacing: 14) {
            ProviderToggleHeader(
                selected: selectedProvider,
                supportsGemini: agentClient.supportsGemini,
                onPick: { picked in pickProvider(picked) }
            )

            Group {
                switch selectedProvider {
                case .claude: claudePane
                case .codex:  codexPane
                case .gemini: geminiPane
                }
            }
            .id(selectedProvider)
            .transition(.asymmetric(
                insertion: .move(edge: swipeDirection).combined(with: .opacity),
                removal: .move(edge: swipeDirection == .leading ? .trailing : .leading).combined(with: .opacity)
            ))
        }
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

    private func toggleProvider(direction: Edge = .trailing) {
        swipeDirection = direction
        let next: LiveProvider = (selectedProvider == .claude) ? .codex : .claude
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            selectedProviderRaw = next.rawValue
        }
    }

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

    @ViewBuilder
    private var geminiPane: some View {
        if agentClient.supportsGemini {
            GeminiSection(snapshot: model.geminiSnapshot, agentClient: agentClient)
        } else {
            UpdateMacForGeminiCard()
        }
    }
}

// MARK: - Provider toggle

/// Provider toggle as a logo segmented control. Both Claude and Codex
/// logos render side-by-side at the top of the gauges section. Tapping a
/// logo switches to that provider; the active one is full-color + larger
/// with a name underneath, the inactive one is dimmed + smaller.
private struct ProviderToggleHeader: View {
    let selected: LiveProvider
    let supportsGemini: Bool
    let onPick: (LiveProvider) -> Void

    var body: some View {
        HStack(spacing: 0) {
            providerButton(.claude)
            providerButton(.codex)
            if supportsGemini {
                providerButton(.gemini)
            }
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
        case .gemini: return "GeminiLogo"
        }
    }

    private func label(for provider: LiveProvider) -> String {
        switch provider {
        case .claude: return "Claude"
        case .codex:  return "Codex"
        case .gemini: return "Gemini"
        }
    }

    private var accent: Color { SessionsV2Theme.accent }
}

private struct ProviderLogo: View {
    let asset: String
    let size: CGFloat

    var body: some View {
        if let img = UIImage(named: asset) {
            let rendered = (asset == "CodexLogo" || asset == "GeminiLogo")
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

// MARK: - Brand colors

private enum ClaudeBrand {
    static let color = TahoeProvider.claude.dot
}

private enum CodexBrand {
    static let color = TahoeProvider.codex.dot
}

private enum GeminiBrand {
    static let color = TahoeProvider.gemini.dot
}

// MARK: - Per-provider sections

private struct ClaudeSection: View {
    @ObservedObject var model: UsageModel
    @AppStorage("clawdmeter.claude.advancedExpanded") private var advancedExpanded: Bool = false

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
        .onAppear {
            model.setAutoReviveEnabled(false)
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
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Auto-revive paused")
                            .font(.system(size: 14, weight: .medium))
                        Text("Quota keepalive is unavailable until Claude exposes a non-consuming endpoint.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 6))
    }
}

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
                HStack(spacing: 4) {
                    Text("Synced from Mac \(snap.writtenAt, style: .relative) ago")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    if AgentControlWireVersion.supportsCodexSDK(serverWireVersion: agentClient.serverWireVersion) {
                        let isSDK = usage.codexSDKModeActive ?? false
                        Text("·")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text(isSDK ? "SDK mode" : "disk mode")
                            .font(.footnote.monospaced())
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(isSDK ? "Codex SDK mode active" : "Codex disk mode")
                    }
                    Spacer()
                }
                .padding(.horizontal, 4)
            } else {
                WaitingForMacCard(agentClient: agentClient)
            }
        }
    }
}

private struct GeminiSection: View {
    let snapshot: UsageStore.Snapshot?
    @ObservedObject var agentClient: AgentControlClient

    var body: some View {
        VStack(spacing: 14) {
            if let snap = snapshot {
                let notStarted = snap.usage.status == .notStarted
                let usage = snap.usage
                SessionCard(
                    title: "Current quota",
                    percent: notStarted ? 0 : usage.sessionPct,
                    resetDate: Date(timeIntervalSince1970: TimeInterval(usage.sessionEpoch)),
                    notStarted: notStarted,
                    tint: GeminiBrand.color
                )
                HStack {
                    Text("Synced from Mac \(snap.writtenAt, style: .relative) ago")
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

// MARK: - Cards (shared by all three provider sections)

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
                    Text("Resets \(resetDate, style: .relative)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 6))
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
                Text("Resets \(resetDate, style: .relative)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct FooterRow: View {
    let updatedAt: Date
    let onRefresh: () -> Void

    var body: some View {
        HStack {
            Text("Last updated \(updatedAt, style: .relative) ago")
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
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct WaitingForMacCard: View {
    @ObservedObject var agentClient: AgentControlClient

    private var isPairedWithMac: Bool {
        agentClient.host != nil && agentClient.token != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isPairedWithMac ? "Waiting for the Mac app" : "Not paired with a Mac")
                .font(.headline)
            Text(isPairedWithMac
                ? "Codex usage syncs from your paired Mac over Tailscale. Open Continuum on the Mac and make sure `~/.codex/sessions/` has at least one rollout."
                : "Codex usage syncs from your paired Mac over Tailscale. Tap **Pair with iPhone** on the Mac, then scan the QR or paste the URL below.")
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
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct UnauthenticatedCard: View {
    @Binding var showingSettings: Bool
    let model: UsageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Waiting for your Mac")
                .font(.title2.bold())
            Text("Open Continuum on your Mac while signed into the same Apple ID — your Claude token will sync over iCloud Keychain and this screen will fill in automatically.")
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
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 6))
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
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct UpdateMacForGeminiCard: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.up.circle")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.secondary)
            Text("Update Clawdmeter on Mac")
                .font(.system(size: 17, weight: .semibold))
            Text("The paired Mac is running an older Clawdmeter. Update to v0.8.0+ on the Mac to unlock Gemini live quota.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(ContinuumTokens.surface2, in: RoundedRectangle(cornerRadius: 8))
    }
}

import SwiftUI
import ClawdmeterShared

/// Spawn-mode config page: pick how many terminal sessions to open (1/2/4/6/8)
/// and the agent mix ("4 Claude, 2 Codex, 2 Cursor"). Spawning opens every
/// terminal in the home directory and selects the new group in the Code tab.
struct SpawnConfigSheet: View {
    @ObservedObject var store: SpawnModeStore
    /// Lets the workspace clear the session/draft/tab selection so the new
    /// spawn grid takes the center pane.
    let onSpawned: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.tahoe) private var t

    @State private var sessionCount: Int = SpawnPlan.sessionCountOptions[0]
    @State private var counts: [AgentKind: Int] = [:]
    @State private var isSpawning = false
    @State private var spawnErrorMessage: String?
    /// Availability resolved ONCE on appear — `binaryPath` falls through to
    /// a synchronous `/usr/bin/which` for uninstalled CLIs, which must not
    /// run per body evaluation.
    @State private var availability: [AgentKind: SpawnAgentAvailability] = [:]
    /// Embedded install terminal for a missing agent CLI (same
    /// `SetupTerminalSheet` flow onboarding uses). Auth happens on the
    /// CLI's own first run inside the spawn tile.
    @State private var installTerminal: SetupTerminalSession?

    private var spawnableAgents: [AgentKind] {
        SpawnPlan.selectableAgents.filter { availability[$0]?.isSpawnable == true }
    }

    private var allocatedCount: Int {
        counts.values.reduce(0, +)
    }

    private var remainingCount: Int {
        sessionCount - allocatedCount
    }

    private var allocations: [SpawnAgentAllocation] {
        SpawnPlan.selectableAgents.compactMap { agent in
            guard let count = counts[agent], count > 0 else { return nil }
            return SpawnAgentAllocation(agent: agent, count: count)
        }
    }

    private var canSpawn: Bool {
        remainingCount == 0 && !allocations.isEmpty && !isSpawning
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            TahoeHairline()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    countSection
                    agentSection
                }
                .padding(20)
            }
            TahoeHairline()
            footer
        }
        .frame(width: 440, height: 520)
        .background(t.surface1)
        .interactiveDismissDisabled(isSpawning)
        .onAppear {
            resolveAvailability()
            seedDefaultAllocation()
        }
        .onChange(of: sessionCount) { _, newTotal in
            counts = SpawnPlan.rebalancedAllocation(
                counts,
                total: newTotal,
                availableAgents: spawnableAgents
            )
        }
        // Re-probe on EVERY dismissal path (Done button AND Esc swipe-away):
        // onDismiss is the one hook both share. A just-installed CLI must
        // flip its row live, and a previously-empty allocation must re-seed
        // so the first install restores the two-click flow.
        .sheet(item: $installTerminal, onDismiss: {
            availability = [:]
            resolveAvailability()
            seedDefaultAllocation()
        }) { terminal in
            SetupTerminalSheet(terminal: terminal) {
                installTerminal = nil
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(t.fg2)
            VStack(alignment: .leading, spacing: 1) {
                Text("New spawn")
                    .font(TahoeFont.body(15, weight: .bold))
                    .foregroundStyle(t.fg)
                Text("Open a grid of agent terminals in your home directory")
                    .font(TahoeFont.body(11))
                    .foregroundStyle(t.fg3)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(t.fg3)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(isSpawning)
            .accessibilityLabel("Cancel")
            .accessibilityIdentifier("code.spawn.sheet.cancel")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var countSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Sessions")
            HStack(spacing: 8) {
                ForEach(SpawnPlan.sessionCountOptions, id: \.self) { option in
                    Button {
                        sessionCount = option
                    } label: {
                        Text("\(option)")
                            .font(TahoeFont.mono(14, weight: .semibold))
                            .foregroundStyle(sessionCount == option ? t.fg : t.fg2)
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(sessionCount == option ? t.segmentActiveFill : Color.clear)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .stroke(sessionCount == option ? t.focus : t.hairline, lineWidth: 0.5)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableButtonStyle())
                    .accessibilityLabel("\(option) session\(option == 1 ? "" : "s")")
                    .accessibilityIdentifier("code.spawn.sheet.count.\(option)")
                }
            }
        }
    }

    private var agentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionLabel("Agent mix")
                Spacer()
                Text(remainingCount == 0
                     ? "\(allocatedCount) of \(sessionCount) allocated"
                     : "\(remainingCount) unallocated")
                    .font(TahoeFont.mono(10.5))
                    .foregroundStyle(remainingCount == 0 ? t.fg3 : t.warn)
                    .accessibilityIdentifier("code.spawn.sheet.allocation")
            }
            VStack(spacing: 0) {
                ForEach(Array(SpawnPlan.selectableAgents.enumerated()), id: \.element) { index, agent in
                    if index > 0 { TahoeHairline() }
                    agentRow(agent)
                }
            }
            .background(t.surface2, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(t.hairline, lineWidth: 0.5)
            )
            if spawnableAgents.isEmpty {
                Text("No agent CLIs found. Install claude, codex, or cursor-agent and reopen this sheet.")
                    .font(TahoeFont.body(10.5))
                    .foregroundStyle(t.warn)
            }
        }
    }

    private func agentRow(_ agent: AgentKind) -> some View {
        let agentAvailability = availability[agent]
            ?? SpawnAgentAvailability(installed: false, enabled: true)
        let spawnable = agentAvailability.isSpawnable
        let count = counts[agent] ?? 0
        return HStack(spacing: 10) {
            ProviderDot(agent.tahoeProvider, size: 6)
            TahoeProviderGlyph(provider: agent.tahoeProvider, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(AgentKindUI.displayName(for: agent))
                    .font(TahoeFont.body(12.5, weight: .semibold))
                    .foregroundStyle(spawnable ? t.fg : t.fg4)
                if !agentAvailability.installed {
                    Text("CLI not found on PATH")
                        .font(TahoeFont.mono(9.5))
                        .foregroundStyle(t.fg4)
                } else if !agentAvailability.enabled {
                    Text("Disabled in Settings → Providers")
                        .font(TahoeFont.mono(9.5))
                        .foregroundStyle(t.fg4)
                }
            }
            Spacer()
            if !agentAvailability.installed {
                Button("Install…") {
                    launchInstallTerminal(for: agent)
                }
                .buttonStyle(.plain)
                .font(TahoeFont.body(11, weight: .semibold))
                .foregroundStyle(t.accent)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(t.accentAlpha(0.32), lineWidth: 0.5)
                )
                .help("Install the \(AgentKindUI.displayName(for: agent)) CLI in an embedded terminal — sign in on its first run inside the spawn tile")
                .accessibilityLabel("Install the \(AgentKindUI.displayName(for: agent)) CLI")
                .accessibilityIdentifier("code.spawn.sheet.install.\(agent.rawValue)")
            } else {
                stepper(for: agent, count: count, spawnable: spawnable)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .opacity(spawnable ? 1 : 0.6)
    }

    private func stepper(for agent: AgentKind, count: Int, spawnable: Bool) -> some View {
        HStack(spacing: 0) {
            Button {
                counts[agent] = max(0, count - 1)
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 26, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(!spawnable || count == 0)
            .foregroundStyle(count == 0 ? t.fg4 : t.fg2)
            .accessibilityLabel("Remove a \(AgentKindUI.displayName(for: agent)) session")
            .accessibilityIdentifier("code.spawn.sheet.minus.\(agent.rawValue)")

            Text("\(count)")
                .font(TahoeFont.mono(12.5, weight: .semibold))
                .foregroundStyle(count > 0 ? t.fg : t.fg3)
                .frame(width: 26)
                .accessibilityIdentifier("code.spawn.sheet.value.\(agent.rawValue)")

            Button {
                // When the batch is full, "+" auto-debits the default
                // (first spawnable) agent instead of being a dead button.
                counts = SpawnPlan.incrementAllocation(
                    counts,
                    agent: agent,
                    total: sessionCount,
                    availableAgents: spawnableAgents
                )
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 26, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(!spawnable || count >= sessionCount)
            .foregroundStyle(count >= sessionCount ? t.fg4 : t.fg2)
            .accessibilityLabel("Add a \(AgentKindUI.displayName(for: agent)) session")
            .accessibilityIdentifier("code.spawn.sheet.plus.\(agent.rawValue)")
        }
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(t.hairline, lineWidth: 0.5)
        )
    }

    private var footer: some View {
        HStack {
            if let spawnErrorMessage {
                Text(spawnErrorMessage)
                    .font(TahoeFont.body(10.5))
                    .foregroundStyle(t.error)
                    .lineLimit(2)
                    .accessibilityIdentifier("code.spawn.sheet.error")
            } else {
                Text("Each session opens its agent CLI in ~")
                    .font(TahoeFont.mono(10))
                    .foregroundStyle(t.fg4)
            }
            Spacer()
            Button {
                spawn()
            } label: {
                HStack(spacing: 6) {
                    if isSpawning {
                        ProgressView().controlSize(.small)
                    }
                    Text(isSpawning ? "Spawning…" : "Spawn \(sessionCount) session\(sessionCount == 1 ? "" : "s")")
                        .font(TahoeFont.body(12.5, weight: .bold))
                }
                .foregroundStyle(canSpawn ? t.primaryText : t.fg4)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(canSpawn ? t.primaryFill : t.surface3)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(!canSpawn)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("code.spawn.sheet.spawn")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(TahoeFont.mono(10.5, weight: .semibold))
            .tracking(1.0)
            .textCase(.uppercase)
            .foregroundStyle(t.fg3)
    }

    // MARK: - Allocation bookkeeping

    private func resolveAvailability() {
        guard availability.isEmpty else { return }
        var resolved: [AgentKind: SpawnAgentAvailability] = [:]
        for agent in SpawnPlan.selectableAgents {
            resolved[agent] = SpawnModeStore.agentAvailability(agent)
        }
        availability = resolved
    }

    /// Install action per agent CLI — `ProviderDeviceSetupAction` is the
    /// one install-command inventory (onboarding + Settings read it too).
    private static func installAction(for agent: AgentKind) -> ProviderDeviceSetupAction? {
        switch agent {
        case .claude:   return .installClaudeCLI
        case .codex:    return .installCodexCLI
        case .cursor:   return .installCursorCLI
        case .grok:     return .installGrokCLI
        case .gemini:   return .installGeminiCLI
        case .opencode: return .installOpencodeCLI
        case .unknown:  return nil
        }
    }

    private func launchInstallTerminal(for agent: AgentKind) {
        guard let command = Self.installAction(for: agent)?.shellCommand else { return }
        let title = "Install \(AgentKindUI.displayName(for: agent)) CLI"
        Task { @MainActor in
            do {
                installTerminal = try await SetupTerminalSession.launch(title: title, command: command)
            } catch {
                spawnErrorMessage = "Couldn't open the install terminal: \(error.localizedDescription)"
            }
        }
    }

    private func seedDefaultAllocation() {
        guard counts.isEmpty else { return }
        counts = SpawnPlan.seededAllocation(total: sessionCount, availableAgents: spawnableAgents)
    }

    private func spawn() {
        guard canSpawn else { return }
        isSpawning = true
        spawnErrorMessage = nil
        let allocations = self.allocations
        Task { @MainActor in
            let result = await store.createGroup(allocations: allocations)
            isSpawning = false
            guard let group = result.group else {
                spawnErrorMessage = "Couldn't start any sessions — check the agent CLIs are installed and runnable."
                return
            }
            if !result.failedSlotTitles.isEmpty {
                NotificationCenter.default.post(
                    name: .clawdmeterShowTransientToast,
                    object: nil,
                    userInfo: ["toast": TransientToast(
                        title: "Spawned \(group.tiles.count) of \(group.tiles.count + result.failedSlotTitles.count) sessions — \(result.failedSlotTitles.joined(separator: ", ")) failed to start",
                        severity: .failure
                    )]
                )
            }
            onSpawned()
            dismiss()
        }
    }
}

import AppKit
import SwiftUI
import ClawdmeterShared

/// First-run welcome. Scans the Mac for installed/authenticated providers,
/// pre-selects ready ones, and offers setup actions for the rest.
struct OnboardingSheet: View {
    @Environment(\.tahoe) private var t
    var runtime: AppRuntime?
    var onDone: () -> Void

    private enum Phase: Equatable {
        case scanning
        case review(ProviderDiscoveryResult)
    }

    @State private var phase: Phase = .scanning
    /// Staged selections — nothing touches `ProviderEnablement` (pollers,
    /// menu-bar items) until Continue, so abandoning the sheet leaves no
    /// persisted side effects behind.
    @State private var stagedProviderIDs = Set(ProviderEnablement.enabledProviderIDs())
    /// Providers the user ran a setup action for; auto-staged once a
    /// re-check finds them ready (matches the OpenRouter key-save behavior).
    @State private var pendingSetupProviderIDs: Set<String> = []
    @State private var discoveryResult: ProviderDiscoveryResult?
    @State private var isRefreshingDiscovery = false
    @State private var openRouterKeyDraft = ""
    @State private var isSavingOpenRouterKey = false
    @State private var openRouterKeyMessage: String?
    @State private var opencodeSetupCommand: OpencodeSetupSheet.Command?
    @State private var setupTerminal: OnboardingSetupTerminal?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            content
            footer
        }
        .padding(24)
        .frame(width: 600)
        .background(t.surfaceSolid)
        .task { await runInitialDiscovery() }
        .sheet(item: $opencodeSetupCommand) { command in
            OpencodeSetupSheet(command: command) {
                Task { await refreshDiscovery() }
            }
        }
        .sheet(item: $setupTerminal) { terminal in
            OnboardingSetupTerminalSheet(terminal: terminal) {
                setupTerminal = nil
                Task { await refreshDiscovery() }
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Choose providers")
                .font(TahoeFont.body(20, weight: .bold))
                .foregroundStyle(t.fg)
            Text(headerSubtitle)
                .font(TahoeFont.body(12.5))
                .foregroundStyle(t.fg3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var headerSubtitle: String {
        switch phase {
        case .scanning:
            return "Checking which coding tools are already installed on your Mac…"
        case .review(let result):
            let ready = result.readyProviderIDs.count
            if ready == 0 {
                return "Turn on the providers you want. We didn't find any fully set up yet — use the actions below to install or sign in."
            }
            if ready == 1 {
                return "We found 1 provider ready to use and turned it on. Adjust selections or set up the others below."
            }
            return "We found \(ready) providers ready to use and turned them on. Adjust selections or set up the others below."
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .scanning:
            TahoeGlass(radius: 6, tone: .panel) {
                HStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Scanning your Mac…")
                        .font(TahoeFont.body(13, weight: .medium))
                        .foregroundStyle(t.fg2)
                    Spacer(minLength: 0)
                }
                .padding(20)
            }
        case .review:
            if let discoveryResult {
                confirmationBanner(result: discoveryResult)
            }
            TahoeGlass(radius: 6, tone: .panel) {
                ProviderPreferenceRows(
                    client: runtime?.loopbackClient,
                    runtime: runtime,
                    showDeviceStatus: true,
                    deviceStatuses: discoveryStatuses,
                    onSetupAction: { providerId, action in
                        Task { await performSetup(providerId: providerId, action: action) }
                    },
                    stagedEnabledProviderIDs: $stagedProviderIDs
                )
                .padding(16)
            }
            if showOpenRouterKeyField {
                openRouterKeyPanel
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if case .review = phase, stagedProviderIDs.isEmpty {
                Text("Turn on at least one provider to continue.")
                    .font(TahoeFont.body(12.5, weight: .medium))
                    .foregroundStyle(Color.orange)
            }
            HStack {
                if case .review = phase {
                    Button {
                        Task { await refreshDiscovery() }
                    } label: {
                        HStack(spacing: 6) {
                            TahoeIcon("refresh", size: 11, weight: .bold)
                            Text(isRefreshingDiscovery ? "Checking…" : "Re-check device")
                        }
                        .font(TahoeFont.body(12, weight: .semibold))
                        .foregroundStyle(t.fg2)
                    }
                    .buttonStyle(.plain)
                    .disabled(isRefreshingDiscovery)
                }
                Spacer()
                Button {
                    guard !stagedProviderIDs.isEmpty else { return }
                    applyStagedSelections()
                    ProviderEnablement.hasOnboarded = true
                    onDone()
                } label: {
                    Text(continueLabel)
                        .font(TahoeFont.body(13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 22).padding(.vertical, 9)
                        .background(t.accent, in: Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!canContinue)
                .opacity(canContinue ? 1 : 0.55)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var continueLabel: String {
        guard case .review(let result) = phase else { return "Continue" }
        let ready = result.readyProviderIDs.count
        if ready > 0, stagedProviderIDs == Set(result.readyProviderIDs) {
            return "Continue with \(ready) provider\(ready == 1 ? "" : "s")"
        }
        return "Continue"
    }

    private var canContinue: Bool {
        guard case .review = phase else { return false }
        return !stagedProviderIDs.isEmpty
    }

    private var discoveryStatuses: [String: ProviderDeviceStatus] {
        guard let discoveryResult else { return [:] }
        return Dictionary(uniqueKeysWithValues: discoveryResult.statuses.map { ($0.providerId, $0) })
    }

    private var showOpenRouterKeyField: Bool {
        guard let status = discoveryResult?.status(for: "opencode") else { return false }
        return !status.authenticated && status.setupActions.contains(.addOpenRouterKey)
    }

    @ViewBuilder
    private func confirmationBanner(result: ProviderDiscoveryResult) -> some View {
        let ready = result.readyProviderIDs.count
        if ready > 0 {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(ready) provider\(ready == 1 ? " is" : "s are") ready on this Mac")
                        .font(TahoeFont.body(13, weight: .semibold))
                        .foregroundStyle(t.fg)
                    Text(readyProviderSummary(result))
                        .font(TahoeFont.body(12))
                        .foregroundStyle(t.fg3)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(t.accentAlpha(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(t.hairline, lineWidth: 0.5)
            }
        }
    }

    private var openRouterKeyPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("OpenRouter API key")
                .font(TahoeFont.body(12.5, weight: .semibold))
                .foregroundStyle(t.fg)
            HStack(spacing: 8) {
                SecureField("sk-or-…", text: $openRouterKeyDraft)
                    .textFieldStyle(.roundedBorder)
                Button {
                    Task { await saveOpenRouterKey() }
                } label: {
                    Text(isSavingOpenRouterKey ? "Saving…" : "Save")
                        .font(TahoeFont.body(12, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .disabled(openRouterKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSavingOpenRouterKey)
            }
            if let openRouterKeyMessage {
                Text(openRouterKeyMessage)
                    .font(TahoeFont.body(11.5))
                    .foregroundStyle(t.fg3)
            }
        }
        .padding(12)
        .background(t.glassTintHi.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: - Discovery

    private func runInitialDiscovery() async {
        let result = await ProviderDeviceDiscovery.discover()
        await applyDiscovery(result, preselectReady: true)
    }

    private func refreshDiscovery() async {
        isRefreshingDiscovery = true
        defer { isRefreshingDiscovery = false }
        let result = await ProviderDeviceDiscovery.discover()
        await applyDiscovery(result, preselectReady: false)
    }

    @MainActor
    private func applyDiscovery(_ result: ProviderDiscoveryResult, preselectReady: Bool) async {
        discoveryResult = result
        phase = .review(result)
        if preselectReady {
            stagedProviderIDs.formUnion(result.readyProviderIDs)
        }
        // A provider the user just set up (login terminal, key save) gets
        // staged automatically once a re-check finds it ready, so finishing
        // `codex login` behaves like saving an OpenRouter key.
        for id in pendingSetupProviderIDs where result.status(for: id)?.isReady == true {
            stagedProviderIDs.insert(id)
            pendingSetupProviderIDs.remove(id)
        }
    }

    /// Continue applies every staged toggle in one pass. This is the only
    /// place onboarding mutates `ProviderEnablement` / starts pollers.
    private func applyStagedSelections() {
        for id in ProviderEnablement.allProviderIds {
            let desired = stagedProviderIDs.contains(id)
            guard desired != ProviderEnablement.isEnabled(id) else { continue }
            if let runtime {
                runtime.setProviderEnabled(id, desired)
            } else {
                ProviderEnablement.setEnabled(id, desired)
            }
            // Settings' live toggle seeds Continuum's Claude token on enable;
            // staged apply must do the same or the gauge polls empty (0%).
            if id == "claude", desired {
                Task { await importClaudeFromClaudeCode() }
            }
        }
    }

    private func readyProviderSummary(_ result: ProviderDiscoveryResult) -> String {
        result.statuses
            .filter { $0.isReady }
            .map(\.displayName)
            .joined(separator: ", ")
    }

    // MARK: - Setup actions

    private func performSetup(providerId: String, action: ProviderDeviceSetupAction) async {
        await MainActor.run { _ = pendingSetupProviderIDs.insert(providerId) }
        switch action {
        case .importClaudeFromClaudeCode:
            await importClaudeFromClaudeCode()
            await refreshDiscovery()
        case .openAntigravityApp:
            let url = URL(fileURLWithPath: "/Applications/Antigravity.app")
            if FileManager.default.fileExists(atPath: url.path) {
                NSWorkspace.shared.open(url)
            } else {
                NSWorkspace.shared.open(URL(string: "https://antigravity.google")!)
            }
        case .openOpencodeSignIn:
            await MainActor.run { opencodeSetupCommand = .signIn }
        case .addOpenRouterKey:
            await MainActor.run { openRouterKeyDraft = "" }
        case .runCodexLogin, .runCursorAgentLogin, .installCodexCLI, .installCursorCLI,
             .installAgyCLI, .installGrokCLI:
            guard let command = action.shellCommand else { return }
            await launchSetupTerminal(title: action.label, command: command)
        }
    }

    private func importClaudeFromClaudeCode() async {
        let seeded = await Task.detached(priority: .userInitiated) {
            guard let token = KeychainTokenProvider(allowsUserInteraction: true).currentAccessToken,
                  !token.isEmpty else { return false }
            let ok = PastedAnthropicTokenProvider.shared().setToken(token)
            UserDefaults.standard.set(true, forKey: "clawdmeter.claude.autoImportFromClaudeCode")
            return ok
        }.value
        if seeded {
            runtime?.claudeModel.forcePoll()
        }
    }

    private func saveOpenRouterKey() async {
        let key = openRouterKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        isSavingOpenRouterKey = true
        defer { isSavingOpenRouterKey = false }
        do {
            try await OpencodeAuthFile.shared.setAPIKey(providerId: "openrouter", key: key)
            openRouterKeyMessage = "OpenRouter key saved."
            openRouterKeyDraft = ""
            stagedProviderIDs.insert("opencode")
            await refreshDiscovery()
        } catch {
            openRouterKeyMessage = error.localizedDescription
        }
    }

    @MainActor
    private func launchSetupTerminal(title: String, command: String) async {
        let wrapped = "\(command); echo ''; echo 'Press Done when finished.'"
        do {
            let host = try await TerminalPtyRegistry.shared.spawnCommand(
                wrapped,
                cwd: NSHomeDirectory(),
                title: title
            )
            setupTerminal = OnboardingSetupTerminal(id: host.id.uuidString, title: title, host: host)
        } catch {
            // Best-effort fallback: open the user's Terminal.app with the command.
            let script = "tell application \"Terminal\" to do script \"\(command.replacingOccurrences(of: "\"", with: "\\\""))\""
            NSAppleScript(source: script)?.executeAndReturnError(nil)
        }
    }
}

// MARK: - Embedded setup terminal

private struct OnboardingSetupTerminal: Identifiable {
    let id: String
    let title: String
    let host: TerminalPtyHost
}

private struct OnboardingSetupTerminalSheet: View {
    @Environment(\.tahoe) private var t
    let terminal: OnboardingSetupTerminal
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TahoeIcon("terminal", size: 14, weight: .bold)
                    .foregroundStyle(t.accent)
                Text(terminal.title)
                    .font(TahoeFont.body(14, weight: .semibold))
                    .foregroundStyle(t.fg)
                Spacer(minLength: 0)
                Button("Done", action: onClose)
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            TahoeHair()
            DirectPtyTerminalView(host: terminal.host)
                .frame(minWidth: 640, minHeight: 360)
        }
        .frame(minWidth: 640, minHeight: 420)
        .onDisappear {
            Task { await terminal.host.kill() }
        }
    }
}

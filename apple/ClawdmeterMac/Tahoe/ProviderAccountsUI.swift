import SwiftUI
import ClawdmeterShared

// Multi-account v1: Settings → Providers per-account UI for Claude +
// Codex. Lists configured instances under the provider row, hosts the
// Add-account login flow (embedded `claude setup-token` / `codex login`
// terminal), and tears accounts down via `AppRuntime.removeInstance`.

/// Serializes interactive login flows. `codex login` binds a fixed
/// localhost OAuth callback port (1455), so two concurrent logins would
/// race the port; one-at-a-time also keeps the UX unambiguous about
/// which account the browser tab belongs to.
@MainActor
final class InstanceLoginCoordinator: ObservableObject {
    static let shared = InstanceLoginCoordinator()
    @Published private(set) var isActive = false

    /// Returns false when another login is already running.
    func begin() -> Bool {
        guard !isActive else { return false }
        isActive = true
        return true
    }

    func end() {
        isActive = false
    }
}

// MARK: - Accounts section (under a provider row)

/// The per-provider accounts sub-list. Renders only for kinds that
/// support config-dir isolation (Claude / Codex — see
/// `ProviderInstanceEnvironment.configDirVariable`).
private enum ProviderAccountRowMetrics {
    static let defaultColumnWidth: CGFloat = 56
    static let disconnectColumnWidth: CGFloat = 84
    static let trailingColumnSpacing: CGFloat = 10
}

struct ProviderAccountsSection: View {
    @Environment(\.tahoe) private var t
    let runtime: AppRuntime
    let kind: AgentKind

    @State private var instances: [ProviderInstanceId] = []
    @State private var statusByWireId: [String: Bool] = [:]
    @State private var emailByWireId: [String: String] = [:]
    @State private var preferredWireId: String?
    @State private var addSheetShown = false
    @State private var pendingRemoval: ProviderInstanceId?

    static func supportsMultiAccount(_ kind: AgentKind) -> Bool {
        ProviderInstanceEnvironment.configDirVariable(for: kind) != nil
    }

    private var displayedAccounts: [ProviderInstanceId] {
        instances
    }

    private var showsCodeDefaultColumn: Bool {
        displayedAccounts.count >= 2
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if displayedAccounts.count >= 2 {
                accountListHeader
            }
            ForEach(displayedAccounts, id: \.wireId) { instance in
                accountRow(instance)
            }
            Button {
                addSheetShown = true
            } label: {
                HStack(spacing: 5) {
                    TahoeIcon("plus", size: 9, weight: .bold)
                    Text(displayedAccounts.count <= 1 ? "Add another account…" : "Add account…")
                        .font(TahoeFont.body(11, weight: .semibold))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(t.fg2)
            .accessibilityIdentifier("settings.provider.\(kind.rawValue).addAccount")
        }
        .padding(.leading, 40)
        .task { await refresh() }
        .sheet(isPresented: $addSheetShown) {
            AddProviderAccountSheet(runtime: runtime, kind: kind) {
                Task { await refresh() }
            }
        }
        .alert(
            "Disconnect this account?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            presenting: pendingRemoval
        ) { instance in
            Button("Disconnect", role: .destructive) {
                Task {
                    if preferredWireId == instance.wireId {
                        setPreferredAccount(nil)
                    }
                    await runtime.removeInstance(instance, deleteConfigRoot: false)
                    await refresh()
                }
            }
            Button("Disconnect + delete its data", role: .destructive) {
                Task {
                    if preferredWireId == instance.wireId {
                        setPreferredAccount(nil)
                    }
                    await runtime.removeInstance(instance, deleteConfigRoot: true)
                    await refresh()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { instance in
            Text("“\(instance.name)” stops polling and disappears from account pickers. “Disconnect + delete its data” also deletes its sign-in and local history on this Mac.")
        }
    }

    private var accountListHeader: some View {
        HStack(spacing: ProviderAccountRowMetrics.trailingColumnSpacing) {
            Text("\(displayedAccounts.count) accounts")
                .font(TahoeFont.mono(10, weight: .semibold))
                .kerning(0.4)
                .foregroundStyle(t.fg3)
            Spacer(minLength: 8)
            trailingColumnsHeader
        }
    }

    @ViewBuilder
    private var trailingColumnsHeader: some View {
        if showsCodeDefaultColumn {
            Text("Default")
                .font(TahoeFont.mono(10, weight: .semibold))
                .kerning(0.3)
                .foregroundStyle(t.fg3)
                .lineLimit(1)
                .frame(width: ProviderAccountRowMetrics.defaultColumnWidth, alignment: .center)
        }
        Color.clear
            .frame(width: ProviderAccountRowMetrics.disconnectColumnWidth, height: 1)
            .accessibilityHidden(true)
    }

    private func accountRow(_ instance: ProviderInstanceId) -> some View {
        let label = settingsDisplayName(for: instance)
        let email = emailByWireId[instance.wireId]
        let isCodeDefault = isPreferredForCode(instance)
        return HStack(spacing: ProviderAccountRowMetrics.trailingColumnSpacing) {
            Circle()
                .fill(statusByWireId[instance.wireId] == true ? ContinuumTokens.live : ContinuumTokens.error)
                .frame(width: 6, height: 6)
            Text(label)
                .font(TahoeFont.mono(11, weight: .medium))
                .foregroundStyle(t.fg)
            if let email {
                Text(email)
                    .font(TahoeFont.body(10.5))
                    .foregroundStyle(t.fg3)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if statusByWireId[instance.wireId] != true {
                Text("Re-authenticate")
                    .font(TahoeFont.body(10.5))
                    .foregroundStyle(t.fg3)
            }
            Spacer(minLength: 8)
            if showsCodeDefaultColumn {
                codeDefaultPicker(for: instance, label: label, isSelected: isCodeDefault)
                    .frame(width: ProviderAccountRowMetrics.defaultColumnWidth, alignment: .center)
            }
            accountDisconnectButton(for: instance, label: label)
                .frame(width: ProviderAccountRowMetrics.disconnectColumnWidth, alignment: .trailing)
        }
        .frame(minHeight: 22)
        .accessibilityIdentifier("settings.provider.\(instance.wireId).account")
    }

    @ViewBuilder
    private func accountDisconnectButton(for instance: ProviderInstanceId, label: String) -> some View {
        if instance.isPrimary {
            Color.clear
                .frame(height: 1)
                .accessibilityHidden(true)
        } else {
            Button("Disconnect") {
                pendingRemoval = instance
            }
            .buttonStyle(.plain)
            .font(TahoeFont.body(12, weight: .semibold))
            .foregroundStyle(t.fg2)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .help("Disconnect account “\(label)”")
            .accessibilityIdentifier("settings.provider.\(instance.wireId).disconnect")
        }
    }

    private func codeDefaultPicker(
        for instance: ProviderInstanceId,
        label: String,
        isSelected: Bool
    ) -> some View {
        Button {
            setPreferredAccount(instance.isPrimary ? nil : instance.wireId)
        } label: {
            ZStack {
                Image(systemName: "circle")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(isSelected ? t.fg : t.fg4)
                if isSelected {
                    Circle()
                        .fill(t.fg)
                        .frame(width: 6, height: 6)
                }
            }
            .frame(width: 16, height: 16)
        }
        .buttonStyle(.plain)
        .help(isSelected
              ? "“\(label)” is the default Code account"
              : "Use “\(label)” as the default Code account")
        .accessibilityIdentifier("settings.provider.\(instance.wireId).codeDefault")
    }

    private func isPreferredForCode(_ instance: ProviderInstanceId) -> Bool {
        if let preferredWireId {
            return instance.wireId == preferredWireId
        }
        return instance.isPrimary
    }

    private func setPreferredAccount(_ wireId: String?) {
        preferredWireId = wireId
        CodePreferredAccountStore.setPreferred(wireId: wireId, for: kind)
    }

    /// Settings label for an account row. Named secondaries keep their slug;
    /// the back-compat primary is always "default" so both accounts read
    /// as peers.
    private func settingsDisplayName(for instance: ProviderInstanceId) -> String {
        instance.isPrimary ? "default" : instance.name
    }

    private func refresh() async {
        let all = await runtime.providerInstanceRegistry.instances(for: kind)
        var status: [String: Bool] = [:]
        var emails: [String: String] = [:]
        for instance in all {
            status[instance.wireId] = Self.isAuthenticated(instance)
            if status[instance.wireId] == true,
               let email = await ProviderAccountEmailResolver.email(for: instance) {
                emails[instance.wireId] = email
            }
        }
        var storedPreferred = CodePreferredAccountStore.preferredWireId(for: kind)
        if let pref = storedPreferred, !all.contains(where: { $0.wireId == pref }) {
            storedPreferred = nil
            CodePreferredAccountStore.setPreferred(wireId: nil, for: kind)
        }
        instances = all
        statusByWireId = status
        emailByWireId = emails
        preferredWireId = storedPreferred
    }

    /// Per-account credential presence. Claude: token in the instance's
    /// Keychain partition (primary also accepts Claude Code's Keychain
    /// item). Codex: a parseable auth.json under the instance config root
    /// (primary reads the default `~/.codex/auth.json`).
    static func isAuthenticated(_ instance: ProviderInstanceId) -> Bool {
        switch instance.kind {
        case .claude:
            if PastedAnthropicTokenProvider.forInstance(instance).hasToken { return true }
            if instance.isPrimary {
                return KeychainTokenProvider(allowsUserInteraction: false).hasToken
            }
            return false
        case .codex:
            if instance.isPrimary {
                return CodexTokenProvider().currentAccessToken != nil
            }
            guard let root = instance.configRoot, !root.isEmpty else { return false }
            return CodexAuthProbe.validAuthExists(configRoot: URL(fileURLWithPath: root))
        default:
            return false
        }
    }
}

// MARK: - Add-account sheet

/// The add-account flow: name the account, then sign in through an
/// embedded terminal. Claude runs `claude setup-token` (the token is
/// captured from PTY output and stored in the per-instance Keychain
/// partition — `claude /login` is never used for secondaries because
/// Claude Code's Keychain item is shared per OS user and a second
/// login would clobber the primary). Codex runs `codex login` under
/// `CODEX_HOME=<configRoot>`; completion is a parse-valid auth.json.
struct AddProviderAccountSheet: View {
    @Environment(\.tahoe) private var t
    @Environment(\.dismiss) private var dismiss
    let runtime: AppRuntime
    let kind: AgentKind
    let onComplete: () -> Void

    @StateObject private var model = AddProviderAccountModel()
    @ObservedObject private var loginCoordinator = InstanceLoginCoordinator.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            switch model.phase {
            case .naming:
                namingStep
            case .authenticating:
                authenticatingStep
            case .done:
                doneStep
            }
        }
        .padding(20)
        .frame(width: model.phase == .authenticating ? 680 : 440)
        .background(t.surfaceSolid)
        .onDisappear { model.cancel() }
    }

    private var providerDisplayName: String {
        kind == .claude ? "Claude" : "Codex"
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Add \(providerDisplayName) account")
                .font(TahoeFont.body(16, weight: .bold))
                .foregroundStyle(t.fg)
            Text(kind == .claude
                 ? "Signs in a separate Claude subscription via claude setup-token. Your default account is untouched."
                 : "Signs in a separate Codex/ChatGPT subscription via codex login. Your default account is untouched.")
                .font(TahoeFont.body(11.5))
                .foregroundStyle(t.fg3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Naming

    private var namingStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("ACCOUNT NAME")
                    .font(TahoeFont.mono(10, weight: .semibold))
                    .kerning(1.0)
                    .foregroundStyle(t.fg3)
                TextField("work", text: $model.name)
                    .textFieldStyle(.roundedBorder)
                    .font(TahoeFont.mono(12, weight: .medium))
                    .accessibilityIdentifier("addAccount.nameField")
                if let error = model.nameError {
                    Text(error)
                        .font(TahoeFont.body(11))
                        .foregroundStyle(ContinuumTokens.error)
                }
            }
            if loginCoordinator.isActive {
                Text("Another sign-in is already running — finish it first.")
                    .font(TahoeFont.body(11))
                    .foregroundStyle(t.fg3)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                Button("Sign in…") {
                    Task { await model.beginLogin(runtime: runtime, kind: kind) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.name.trimmingCharacters(in: .whitespaces).isEmpty || loginCoordinator.isActive)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("addAccount.signIn")
            }
        }
    }

    // MARK: Authenticating

    @ViewBuilder
    private var authenticatingStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let host = model.terminalHost {
                DirectPtyTerminalView(host: host)
                    .frame(minWidth: 640, minHeight: 320)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(t.hairline, lineWidth: 0.5))
            }
            if kind == .claude {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Complete the sign-in above — the token is captured automatically. Or paste it:")
                        .font(TahoeFont.body(11))
                        .foregroundStyle(t.fg3)
                    HStack(spacing: 8) {
                        SecureField("sk-ant-oat01-…", text: $model.pastedToken)
                            .textFieldStyle(.roundedBorder)
                            .font(TahoeFont.mono(11))
                        Button("Use token") {
                            model.acceptPastedToken()
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.pastedToken.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            if let error = model.loginError {
                Text(error)
                    .font(TahoeFont.body(11))
                    .foregroundStyle(ContinuumTokens.error)
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    model.cancel()
                    dismiss()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: Done

    private var doneStepDetail: String {
        let instance = ProviderInstanceId(
            kind: kind,
            name: model.name,
            homePathOverride: ProviderInstanceStore.configRoot(
                baseDir: runtime.appSupportDirectory,
                kind: kind,
                name: model.name
            ).path
        )
        let base = "Its rate-limit gauge starts polling now, and it appears in Chat and Code account pickers."
        guard let command = ProviderInstanceShellShim.commandName(for: instance) else {
            return base
        }
        return "\(base) In Terminal, run `\(command)` to use this account (same idea as typing `\(kind.rawValue)` for your default)."
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle().fill(ContinuumTokens.live).frame(width: 6, height: 6)
                Text("“\(model.name)” is connected.")
                    .font(TahoeFont.body(13, weight: .semibold))
                    .foregroundStyle(t.fg)
            }
            Text(doneStepDetail)
                .font(TahoeFont.body(11.5))
                .foregroundStyle(t.fg3)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Done") {
                    onComplete()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

// MARK: - Flow model

@MainActor
final class AddProviderAccountModel: ObservableObject {
    enum Phase {
        case naming
        case authenticating
        case done
    }

    @Published var phase: Phase = .naming
    @Published var name = ""
    @Published var nameError: String?
    @Published var loginError: String?
    @Published var pastedToken = ""
    @Published private(set) var terminalHost: TerminalPtyHost?

    private var runtime: AppRuntime?
    private var kind: AgentKind = .claude
    private var instance: ProviderInstanceId?
    private var watchTask: Task<Void, Never>?
    private var ownsLoginGate = false

    /// Validate the slug, create the config root, spawn the login
    /// terminal under the instance env, and start completion detection.
    func beginLogin(runtime: AppRuntime, kind: AgentKind) async {
        let slug = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        name = slug
        nameError = nil
        loginError = nil

        let candidate = ProviderInstanceId(kind: kind, name: slug)
        guard candidate.isValidName else {
            nameError = "Use a short name without “/” — e.g. work, personal, team."
            return
        }
        let existing = await runtime.providerInstanceRegistry.instances(for: kind)
        guard !existing.contains(where: { $0.name == slug }) else {
            nameError = "An account named “\(slug)” already exists for \(kind.rawValue)."
            return
        }
        guard InstanceLoginCoordinator.shared.begin() else {
            nameError = "Another sign-in is already running — finish it first."
            return
        }
        ownsLoginGate = true

        let configRoot = ProviderInstanceStore.configRoot(
            baseDir: runtime.appSupportDirectory, kind: kind, name: slug
        )
        try? FileManager.default.createDirectory(at: configRoot, withIntermediateDirectories: true)
        let instance = ProviderInstanceId(kind: kind, name: slug, homePathOverride: configRoot.path)

        let binaryName = kind == .claude ? "claude" : "codex"
        guard ShellRunner.locateBinary(binaryName) != nil else {
            releaseGate()
            nameError = "\(binaryName) CLI not found on PATH — install it first."
            return
        }

        self.runtime = runtime
        self.kind = kind
        self.instance = instance

        if kind == .claude {
            ClaudeConfigSeeder.seed(at: configRoot)
        }
        if kind == .codex {
            // Re-add after a keep-data removal: a leftover auth.json under
            // this root would satisfy the completion probe IMMEDIATELY —
            // silently connecting the OLD ChatGPT account before the fresh
            // `codex login` even starts. Clear it so completion can only
            // come from the login the user is about to do.
            try? FileManager.default.removeItem(
                at: CodexAuthProbe.authFileURL(configRoot: configRoot)
            )
        }

        let command = kind == .claude ? "claude setup-token" : "codex login"
        let env = ProviderInstanceEnvironment.buildEnv(for: instance)
        do {
            let host = try await TerminalPtyRegistry.shared.spawnCommand(
                command,
                cwd: NSHomeDirectory(),
                title: "Sign in — \(slug)",
                env: env
            )
            terminalHost = host
            phase = .authenticating
            startCompletionWatch(host: host, instance: instance)
        } catch {
            releaseGate()
            nameError = "Couldn't start \(command): \(error.localizedDescription)"
        }
    }

    private func startCompletionWatch(host: TerminalPtyHost, instance: ProviderInstanceId) {
        watchTask?.cancel()
        watchTask = Task { [weak self] in
            switch instance.kind {
            case .claude:
                var scanner = ClaudeSetupTokenScanner()
                for await chunk in await host.outputStream() {
                    if Task.isCancelled { return }
                    if let token = scanner.ingest(chunk) {
                        await self?.completeClaude(token: token)
                        return
                    }
                }
                // PTY ended without a token — leave the user on the
                // paste-token fallback rather than failing the flow.
                await MainActor.run {
                    self?.loginError = "Sign-in ended without a token. Paste it below, or cancel and retry."
                }
            case .codex:
                guard let root = instance.configRoot else { return }
                let rootURL = URL(fileURLWithPath: root)
                while !Task.isCancelled {
                    if CodexAuthProbe.validAuthExists(configRoot: rootURL) {
                        await self?.completeCodex()
                        return
                    }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            default:
                return
            }
        }
    }

    /// Manual fallback for Claude — the user ran `claude setup-token`
    /// themselves or copy/pasted from the terminal.
    func acceptPastedToken() {
        let token = pastedToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        Task { await completeClaude(token: token) }
    }

    private func completeClaude(token: String) async {
        guard let instance, let runtime, phase == .authenticating else { return }
        guard PastedAnthropicTokenProvider.forInstance(instance).setToken(token) else {
            loginError = "Couldn't store the token in the Keychain."
            return
        }
        pastedToken = ""
        await finishAddingInstance(instance, runtime: runtime)
    }

    private func completeCodex() async {
        guard let instance, let runtime, phase == .authenticating else { return }
        await finishAddingInstance(instance, runtime: runtime)
    }

    private func finishAddingInstance(_ instance: ProviderInstanceId, runtime: AppRuntime) async {
        let added = await runtime.addInstance(instance)
        await teardownTerminal()
        releaseGate()
        if added {
            runtime.appModel(for: instance)?.forcePoll()
            phase = .done
        } else {
            loginError = "Couldn't register the account — check the name and try again."
            phase = .naming
        }
    }

    func cancel() {
        watchTask?.cancel()
        watchTask = nil
        Task { await teardownTerminal() }
        releaseGate()
    }

    private func teardownTerminal() async {
        watchTask?.cancel()
        watchTask = nil
        if let host = terminalHost {
            await host.kill()
        }
        terminalHost = nil
    }

    private func releaseGate() {
        if ownsLoginGate {
            InstanceLoginCoordinator.shared.end()
            ownsLoginGate = false
        }
    }
}

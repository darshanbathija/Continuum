import Foundation
import ClawdmeterShared

// MARK: - Wire types

/// Per-provider device probe result for first-run onboarding. Mirrors the
/// infra-vendor `VendorProvisioningCLIAuthStatus` shape but tailored to AI
/// coding providers (Claude, Codex, Antigravity, etc.).
public enum ProviderDeviceAuthStatus: String, Sendable, Equatable {
    case notInstalled
    case installed
    case unauthenticated
    case authenticated
}

/// Action the onboarding sheet can offer when a provider is not ready.
public enum ProviderDeviceSetupAction: String, Sendable, Equatable, Identifiable {
    case importClaudeFromClaudeCode
    case installCodexCLI
    case runCodexLogin
    case installAgyCLI
    case openAntigravityApp
    case installCursorCLI
    case runCursorAgentLogin
    case openOpencodeSignIn
    case addOpenRouterKey
    case installGrokCLI

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .importClaudeFromClaudeCode: return "Import from Claude Code"
        case .installCodexCLI: return "Install codex CLI"
        case .runCodexLogin: return "Run codex login"
        case .installAgyCLI: return "Install agy CLI"
        case .openAntigravityApp: return "Open Antigravity"
        case .installCursorCLI: return "Install cursor-agent"
        case .runCursorAgentLogin: return "Run cursor-agent login"
        case .openOpencodeSignIn: return "Sign in to OpenCode"
        case .addOpenRouterKey: return "Add OpenRouter key"
        case .installGrokCLI: return "Install grok CLI"
        }
    }

    /// Shell one-liner for embedded terminal launch, when applicable.
    public var shellCommand: String? {
        switch self {
        case .installCodexCLI:
            return "npm install -g @openai/codex || echo 'npm not found — install Node first: https://nodejs.org'"
        case .runCodexLogin: return "codex login"
        case .runCursorAgentLogin: return "cursor-agent login"
        case .installCursorCLI:
            return "echo 'Install the Cursor CLI: curl https://cursor.com/install -fsS | bash' && open https://cursor.com"
        case .installAgyCLI:
            return "echo 'Install the Antigravity 2 agy CLI — see https://antigravity.google' && open https://antigravity.google"
        case .installGrokCLI:
            return "echo 'Install the grok CLI from https://x.ai' && open https://x.ai"
        case .importClaudeFromClaudeCode, .openAntigravityApp, .openOpencodeSignIn, .addOpenRouterKey:
            return nil
        }
    }
}

public struct ProviderDeviceStatus: Sendable, Equatable, Identifiable {
    public let providerId: String
    public let displayName: String
    public let cliInstalled: Bool
    public let authenticated: Bool
    public let status: ProviderDeviceAuthStatus
    public let installedBinary: String?
    public let message: String?
    public let setupActions: [ProviderDeviceSetupAction]

    public var id: String { providerId }

    /// Whether onboarding should pre-enable this provider on load.
    public var isReady: Bool {
        switch providerId {
        case "claude":
            // Claude Code keychain or Continuum-imported token is enough;
            // the `claude` binary is optional for chat/usage.
            return authenticated
        case "codex":
            return cliInstalled && authenticated
        case "gemini":
            return cliInstalled && authenticated
        case "opencode":
            // OpenRouter key is the gate; opencode binary helps setup but
            // isn't required to turn the provider on.
            return authenticated
        case "cursor":
            // Passive discovery: binary presence; login deferred to first use.
            return cliInstalled
        case "grok":
            return cliInstalled
        default:
            return cliInstalled && authenticated
        }
    }

    public init(
        providerId: String,
        displayName: String,
        cliInstalled: Bool,
        authenticated: Bool,
        status: ProviderDeviceAuthStatus,
        installedBinary: String? = nil,
        message: String? = nil,
        setupActions: [ProviderDeviceSetupAction] = []
    ) {
        self.providerId = providerId
        self.displayName = displayName
        self.cliInstalled = cliInstalled
        self.authenticated = authenticated
        self.status = status
        self.installedBinary = installedBinary
        self.message = message
        self.setupActions = setupActions
    }
}

public struct ProviderDiscoveryResult: Sendable, Equatable {
    public let statuses: [ProviderDeviceStatus]
    public let readyProviderIDs: [String]
    public let probedAt: Date

    public init(statuses: [ProviderDeviceStatus], probedAt: Date = Date()) {
        self.statuses = statuses
        self.readyProviderIDs = statuses.filter(\.isReady).map(\.providerId)
        self.probedAt = probedAt
    }

    public func status(for providerId: String) -> ProviderDeviceStatus? {
        statuses.first { $0.providerId == providerId }
    }
}

// MARK: - Discovery

/// Filesystem + CLI discovery for first-run onboarding. Unlike
/// `ChatProviderProbe`, this ignores `ProviderEnablement` so we can detect
/// what's already on the device before the user opts in.
public enum ProviderDeviceDiscovery {

    /// Total budget for the probe bundle. A hung probe (slow Keychain, dead
    /// network mount on PATH) must not strand onboarding on the spinner —
    /// after the deadline we fall through to "couldn't check" placeholders
    /// and the user can Re-check device.
    public static let probeTimeout: Duration = .seconds(5)

    public static func discover(timeout: Duration = probeTimeout) async -> ProviderDiscoveryResult {
        // First-wins race. A task group would await BOTH children before
        // returning (group drain), so a hung probe would still strand the
        // caller past the deadline; the stream yields whichever finishes
        // first and the loser's yield is ignored after finish().
        let race = AsyncStream<[ProviderDeviceStatus]?> { continuation in
            Task.detached(priority: .userInitiated) {
                continuation.yield(await probeAll())
                continuation.finish()
            }
            Task {
                try? await Task.sleep(for: timeout)
                continuation.yield(nil)
                continuation.finish()
            }
        }
        var first: [ProviderDeviceStatus]?
        for await value in race {
            first = value
            break
        }
        if let first {
            return ProviderDiscoveryResult(statuses: first)
        }
        return ProviderDiscoveryResult(
            statuses: ProviderEnablement.allProviderIds.map(timedOutStatus(for:))
        )
    }

    private static func probeAll() async -> [ProviderDeviceStatus] {
        let probes = await Task.detached(priority: .userInitiated) {
            (
                claude: probeClaude(),
                codex: probeCodex(),
                gemini: probeGemini(),
                opencode: await probeOpenCode(),
                cursor: probeCursor(),
                grok: probeGrok()
            )
        }.value

        return ProviderEnablement.allProviderIds.compactMap { id -> ProviderDeviceStatus? in
            switch id {
            case "claude": return probes.claude
            case "codex": return probes.codex
            case "gemini": return probes.gemini
            case "opencode": return probes.opencode
            case "cursor": return probes.cursor
            case "grok": return probes.grok
            default: return nil
            }
        }
    }

    private static func timedOutStatus(for id: String) -> ProviderDeviceStatus {
        let displayName: String = {
            switch id {
            case "gemini": return "Antigravity"
            case "opencode": return "OpenRouter"
            default: return ProviderRegistry.descriptor(id: id)?.displayName ?? id.capitalized
            }
        }()
        return ProviderDeviceStatus(
            providerId: id,
            displayName: displayName,
            cliInstalled: false,
            authenticated: false,
            status: .notInstalled,
            message: "Couldn't check this Mac in time — use Re-check device"
        )
    }

    // MARK: Per-provider probes

    /// **Claude** — OAuth lives in Claude Code's Keychain item
    /// (`Claude Code-credentials`) or Continuum's imported copy. The `claude`
    /// binary on PATH is a bonus signal but not required for readiness.
    private static func probeClaude() -> ProviderDeviceStatus {
        let binary = ShellRunner.locateBinary("claude")
        let hasClaudeCodeKeychain = KeychainTokenProvider(allowsUserInteraction: false).hasToken
        let hasImportedToken = PastedAnthropicTokenProvider.shared().currentAccessToken != nil
        let authenticated = hasClaudeCodeKeychain || hasImportedToken
        let cliInstalled = binary != nil
        let status = resolveStatus(cliInstalled: cliInstalled, authenticated: authenticated)
        var actions: [ProviderDeviceSetupAction] = []
        if !authenticated {
            actions.append(.importClaudeFromClaudeCode)
        }
        let message: String? = {
            if authenticated {
                if let binary { return "Signed in · \(URL(fileURLWithPath: binary).lastPathComponent) on PATH" }
                return "Signed in via Claude Code"
            }
            if cliInstalled { return "claude CLI found — sign in via Claude Code" }
            return "Install Claude Code and sign in, then import here"
        }()
        return ProviderDeviceStatus(
            providerId: "claude",
            displayName: "Claude",
            cliInstalled: cliInstalled,
            authenticated: authenticated,
            status: status,
            installedBinary: binary,
            message: message,
            setupActions: actions
        )
    }

    /// **Codex / ChatGPT** — `codex` CLI on PATH + `~/.codex/auth.json`
    /// from `codex login`.
    private static func probeCodex() -> ProviderDeviceStatus {
        let binary = ShellRunner.locateBinary("codex")
        let authenticated = CodexTokenProvider().currentAccessToken != nil
        let cliInstalled = binary != nil
        let status = resolveStatus(cliInstalled: cliInstalled, authenticated: authenticated)
        var actions: [ProviderDeviceSetupAction] = []
        if !cliInstalled {
            // `codex login` without the binary is a dead-end terminal; offer
            // the install first, then login once a re-check finds the CLI.
            actions.append(.installCodexCLI)
        } else if !authenticated {
            actions.append(.runCodexLogin)
        }
        let message: String? = {
            if authenticated && cliInstalled { return "Signed in · codex on PATH" }
            if cliInstalled { return "codex CLI found — run `codex login`" }
            if authenticated { return "Auth file found — install codex CLI" }
            return "Install codex CLI and run `codex login`"
        }()
        return ProviderDeviceStatus(
            providerId: "codex",
            displayName: "Codex",
            cliInstalled: cliInstalled,
            authenticated: authenticated,
            status: status,
            installedBinary: binary,
            message: message,
            setupActions: actions
        )
    }

    /// **Antigravity / Gemini** — headless `agy` CLI (Antigravity 2) or the
    /// Electron app + `~/.gemini/oauth_creds.json`.
    private static func probeGemini() -> ProviderDeviceStatus {
        let agyBinary = ShellRunner.locateBinary("agy")
        let antigravityApp = AntigravityInstall.detect()
        let oauth = AntigravityInstall.checkOAuthValidity()
        let hasOAuth = oauth == .valid || GeminiTokenProvider().currentAccessToken != nil
        let cliInstalled = agyBinary != nil || antigravityApp != .absent
        let authenticated = hasOAuth
        let status = resolveStatus(cliInstalled: cliInstalled, authenticated: authenticated)
        var actions: [ProviderDeviceSetupAction] = []
        if !cliInstalled {
            actions.append(.installAgyCLI)
            actions.append(.openAntigravityApp)
        } else if !authenticated {
            actions.append(.openAntigravityApp)
        }
        let message: String? = {
            if authenticated && agyBinary != nil { return "Signed in · agy on PATH" }
            if authenticated, case .installed(let info) = antigravityApp {
                let version = info.appVersion.map { " v\($0)" } ?? ""
                return "Signed in · Antigravity\(version)"
            }
            if agyBinary != nil { return "agy CLI found — sign in to Antigravity" }
            if cliInstalled { return "Antigravity installed — sign in to continue" }
            return "Install agy CLI or Antigravity app"
        }()
        return ProviderDeviceStatus(
            providerId: "gemini",
            displayName: "Antigravity",
            cliInstalled: cliInstalled,
            authenticated: authenticated,
            status: status,
            installedBinary: agyBinary,
            message: message,
            setupActions: actions
        )
    }

    /// **OpenRouter / OpenCode** — OpenRouter API key in
    /// `~/.local/share/opencode/auth.json` or `$OPENROUTER_API_KEY`. The
    /// opencode binary enables in-app `auth login` but isn't required to
    /// enable the provider.
    private static func probeOpenCode() async -> ProviderDeviceStatus {
        let binary = await MainActor.run {
            OpencodeProcessManager.shared.locateBinary()
        }
        let openRouterKey = await OpencodeAuthFile.shared.apiKey(providerId: "openrouter")
        let envKey = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let authenticated = (openRouterKey?.isEmpty == false) || (envKey?.isEmpty == false)
        let cliInstalled = binary != nil
        let status = resolveStatus(cliInstalled: cliInstalled, authenticated: authenticated)
        var actions: [ProviderDeviceSetupAction] = []
        if !authenticated {
            actions.append(.addOpenRouterKey)
            if cliInstalled {
                actions.append(.openOpencodeSignIn)
            }
        }
        let message: String? = {
            if authenticated { return "OpenRouter key configured" }
            if cliInstalled { return "Add an OpenRouter API key or sign in via opencode" }
            return "Add an OpenRouter API key in Settings"
        }()
        return ProviderDeviceStatus(
            providerId: "opencode",
            displayName: "OpenRouter",
            cliInstalled: cliInstalled,
            authenticated: authenticated,
            status: status,
            installedBinary: binary,
            message: message,
            setupActions: actions
        )
    }

    /// **Cursor** — `cursor-agent` (or legacy `agent`) on PATH. Passive
    /// discovery avoids Keychain reads; login is deferred to first spawn.
    private static func probeCursor() -> ProviderDeviceStatus {
        let binary = ShellRunner.locateBinary("cursor-agent") ?? ShellRunner.locateBinary("agent")
        let cliInstalled = binary != nil
        let status: ProviderDeviceAuthStatus = cliInstalled ? .installed : .notInstalled
        let actions: [ProviderDeviceSetupAction] = cliInstalled
            ? [.runCursorAgentLogin]
            : [.installCursorCLI]
        let message: String? = cliInstalled
            ? "cursor-agent on PATH — run login before first use"
            : "Install cursor-agent CLI"
        return ProviderDeviceStatus(
            providerId: "cursor",
            displayName: "Cursor",
            cliInstalled: cliInstalled,
            // Passive discovery never probes Cursor's Keychain, so auth is
            // honestly unknown here; readiness keys off the binary alone.
            authenticated: false,
            status: status,
            installedBinary: binary,
            message: message,
            setupActions: actions
        )
    }

    /// **Grok** — `grok` binary on PATH; ACP auth comes from the CLI at
    /// session start (same passive model as ChatProviderProbe).
    private static func probeGrok() -> ProviderDeviceStatus {
        let binary = ShellRunner.locateBinary("grok")
        let cliInstalled = binary != nil
        // Same passive model as Cursor: binary presence is an "Installed"
        // signal, not proof of auth — the ACP handshake authenticates at
        // session start. Don't claim "Ready/authenticated" off the binary.
        let status: ProviderDeviceAuthStatus = cliInstalled ? .installed : .notInstalled
        let actions: [ProviderDeviceSetupAction] = cliInstalled ? [] : [.installGrokCLI]
        let message: String? = cliInstalled
            ? "grok CLI on PATH — signs in at first session"
            : "Install grok CLI"
        return ProviderDeviceStatus(
            providerId: "grok",
            displayName: "Grok",
            cliInstalled: cliInstalled,
            authenticated: false,
            status: status,
            installedBinary: binary,
            message: message,
            setupActions: actions
        )
    }

    private static func resolveStatus(
        cliInstalled: Bool,
        authenticated: Bool
    ) -> ProviderDeviceAuthStatus {
        if authenticated { return .authenticated }
        if cliInstalled { return .unauthenticated }
        return .notInstalled
    }
}

import Foundation
import OSLog
import ClawdmeterShared

private let probeLogger = Logger(subsystem: "com.clawdmeter.mac", category: "ChatProviderProbe")

/// v0.9.x — full ChatProviderProbe (P1 actor) with in-flight de-dup +
/// 60s TTL cache for `/chat-providers`.
///
/// Replaces the minimal inline probe (`handleGetChatProviders` in
/// AgentControlServer.swift) which built a fresh response per request
/// from raw binary-on-PATH checks. The actor:
///   - caches the full ChatProvidersResponse for 60s (Codex P1
///     thundering-herd risk: 6+ iOS clients all asking on app-launch)
///   - de-dupes concurrent probes via in-flight Task storage (only
///     one underlying probe runs even if 10 callers ask simultaneously)
///   - records per-provider auth state flips from
///     `ChatProviderAuthObserver` so a recently-failed OAuth surfaces
///     `authenticated=false` immediately (not 60s later)
///
/// The actor is shared (`ChatProviderProbe.shared`) and called from
/// `handleGetChatProviders` instead of building the response inline.
public actor ChatProviderProbe {

    public static let shared = ChatProviderProbe()

    private struct CacheEntry {
        let response: ChatProvidersResponse
        let computedAt: Date
    }
    private var cache: CacheEntry?
    /// In-flight probe task; subsequent callers await this task instead
    /// of starting a parallel probe (Codex P1 thundering-herd defense).
    private var inflight: Task<ChatProvidersResponse, Never>?

    /// Per-provider/backend auth overrides set by AuthObserver. Keyed by
    /// "claude" / "codex:sdk" / "codex:cli" / "gemini". When present,
    /// the next probe surfaces these values regardless of what the
    /// binary checks say. Cleared when the user re-auths (CodexSDKManager
    /// notify, manual probe invalidate).
    private var authOverrides: [String: (authenticated: Bool, reason: String?)] = [:]

    /// Cache TTL — how long a probed response stays valid before the
    /// next request triggers a re-probe. 60s balances freshness against
    /// the cost of running 4 binary checks per request.
    public static let cacheTTL: TimeInterval = 60

    public init() {}

    /// Returns the cached probe response if fresh; otherwise launches
    /// (or joins) the in-flight probe task. Idempotent under concurrent
    /// callers — only one underlying probe runs at a time.
    public func currentProviders() async -> ChatProvidersResponse {
        // Fresh cache: return immediately.
        if let entry = cache,
           Date().timeIntervalSince(entry.computedAt) < Self.cacheTTL {
            return entry.response
        }
        // In-flight probe: await it. Multiple callers all join one Task.
        if let task = inflight {
            return await task.value
        }
        // No fresh cache and no in-flight probe: kick one off.
        let task = Task { await self.runProbe() }
        inflight = task
        let result = await task.value
        // The probe stores its own result in `cache` before returning;
        // we clear the in-flight slot here.
        inflight = nil
        return result
    }

    /// Force the next call to re-probe (skip the cache). Called by:
    ///   - manual user "Re-check" affordance in Settings (TBD)
    ///   - CodexSDKManager when the user toggles SDK provisioning
    ///   - ChatProviderAuthObserver when it detects an auth failure
    public func invalidate() {
        cache = nil
    }

    /// Push an auth override from `ChatProviderAuthObserver`. Keyed by
    /// `providerKey()` — call invalidate() to force a fresh probe that
    /// reflects this override.
    public func setAuthOverride(providerKey: String, authenticated: Bool, reason: String?) {
        authOverrides[providerKey] = (authenticated, reason)
        cache = nil  // next probe rebuilds with the new override
    }

    /// Clear an auth override (e.g. when the user re-OAuth's). Frees
    /// the next probe to derive auth state from the binary check
    /// instead of the cached failure.
    public func clearAuthOverride(providerKey: String) {
        authOverrides.removeValue(forKey: providerKey)
        cache = nil
    }

    // MARK: - Probe internals

    private func runProbe() async -> ChatProvidersResponse {
        let now = Date()
        // Run the binary checks off the actor to avoid blocking on
        // ShellRunner.locateBinary's PATH walk. (Actor will serialize
        // re-entry into this method anyway via `inflight`.)
        let probes: (
            claudeAvailable: Bool,
            codexAvailable: Bool,
            codexSDKAvailable: Bool,
            agentapiLive: Bool,
            opencodeAvailable: Bool,
            opencodeAuthProviderCount: Int,
            opencodeEnvironmentAuthAvailable: Bool,
            cursorState: CursorModelProbeState
        ) = await Task.detached {
            let claudeAvailable = ShellRunner.locateBinary("claude") != nil
            let codexAvailable = ShellRunner.locateBinary("codex") != nil
            // CodexSDKManager is @MainActor — hop for the read.
            let codexSDKAvailable = await MainActor.run { CodexSDKManager.shared.isProvisioned }
            // Antigravity LS live probe is cheap (one localhost HEAD).
            let lsLive: Bool = await MainActor.run {
                if case .live = LanguageServerClient().discoverLive() { return true }
                return false
            }
            let opencodeAvailable = await MainActor.run {
                OpencodeProcessManager.shared.locateBinary() != nil
            }
            let opencodeAuthProviderCount = await OpencodeAuthFile.shared.providerIds().count
            let opencodeEnvironmentAuthAvailable = ProcessInfo.processInfo.environment.contains { key, value in
                guard !value.isEmpty else { return false }
                switch key {
                case "OPENROUTER_API_KEY",
                     "ANTHROPIC_API_KEY",
                     "OPENAI_API_KEY",
                     "GOOGLE_GENERATIVE_AI_API_KEY",
                     "GEMINI_API_KEY",
                     "MISTRAL_API_KEY",
                     "GROQ_API_KEY",
                     "XAI_API_KEY",
                     "DEEPSEEK_API_KEY",
                     "MOONSHOT_API_KEY",
                     "MOONSHOTAI_API_KEY":
                    return true
                default:
                    return false
                }
            }
            let cursorState = await CursorModelProbe.shared.currentState()
            return (
                claudeAvailable,
                codexAvailable,
                codexSDKAvailable,
                lsLive,
                opencodeAvailable,
                opencodeAuthProviderCount,
                opencodeEnvironmentAuthAvailable,
                cursorState
            )
        }.value

        // Apply per-provider auth overrides. nil override → fall back
        // to the binary check; non-nil → use the observer's verdict.
        func resolveAuth(key: String, fallback: Bool) -> (Bool, String?) {
            if let override = authOverrides[key] {
                return (override.authenticated, override.reason)
            }
            return (fallback, nil)
        }

        let (claudeAuth, claudeReason) = resolveAuth(key: "claude", fallback: probes.claudeAvailable)
        let (codexSDKAuth, codexSDKReason) = resolveAuth(key: "codex:sdk", fallback: probes.codexSDKAvailable)
        let (codexCLIAuth, codexCLIReason) = resolveAuth(key: "codex:cli", fallback: probes.codexAvailable)
        let (geminiAuth, geminiReason) = resolveAuth(key: "gemini", fallback: probes.agentapiLive)
        let (opencodeAuth, opencodeReason) = resolveAuth(
            key: "opencode",
            fallback: probes.opencodeAvailable
                && (probes.opencodeAuthProviderCount > 0 || probes.opencodeEnvironmentAuthAvailable)
        )
        let (cursorAuth, cursorReason) = resolveAuth(
            key: "cursor",
            fallback: probes.cursorState.authenticated
        )
        let opencodeDefaultReason: String? = {
            if !probes.opencodeAvailable { return "opencode CLI not installed" }
            if probes.opencodeAuthProviderCount == 0 && !probes.opencodeEnvironmentAuthAvailable {
                return "Add an OpenCode provider key in Settings"
            }
            return nil
        }()

        let response = ChatProvidersResponse(providers: [
            ChatProviderEntry(
                provider: .claude,
                available: probes.claudeAvailable,
                authenticated: claudeAuth,
                capabilityProbePassed: probes.claudeAvailable && claudeAuth,
                lastProbedAt: now,
                reason: claudeReason ?? (probes.claudeAvailable ? nil : "claude CLI not on PATH")
            ),
            ChatProviderEntry(
                provider: .codex, codexBackend: .sdk,
                available: probes.codexSDKAvailable,
                authenticated: codexSDKAuth,
                capabilityProbePassed: probes.codexSDKAvailable && codexSDKAuth,
                lastProbedAt: now,
                reason: codexSDKReason ?? (probes.codexSDKAvailable ? nil : "Toggle SDK mode in Settings → Codex SDK")
            ),
            ChatProviderEntry(
                provider: .codex, codexBackend: .cli,
                available: probes.codexAvailable,
                authenticated: codexCLIAuth,
                capabilityProbePassed: probes.codexAvailable && codexCLIAuth,
                lastProbedAt: now,
                reason: codexCLIReason ?? (probes.codexAvailable ? nil : "codex CLI not on PATH")
            ),
            ChatProviderEntry(
                provider: .gemini,
                available: probes.agentapiLive,
                authenticated: geminiAuth,
                capabilityProbePassed: probes.agentapiLive && geminiAuth,
                lastProbedAt: now,
                reason: geminiReason ?? (probes.agentapiLive ? nil : "Open Antigravity 2 to start a Gemini chat")
            ),
            ChatProviderEntry(
                provider: .opencode,
                available: probes.opencodeAvailable,
                authenticated: opencodeAuth,
                capabilityProbePassed: probes.opencodeAvailable && opencodeAuth,
                lastProbedAt: now,
                reason: opencodeReason ?? opencodeDefaultReason
            ),
            ChatProviderEntry(
                provider: .cursor,
                available: probes.cursorState.binaryPath != nil,
                authenticated: cursorAuth,
                capabilityProbePassed: probes.cursorState.binaryPath != nil && cursorAuth,
                lastProbedAt: now,
                reason: cursorReason ?? probes.cursorState.reason
            ),
        ])
        cache = CacheEntry(response: response, computedAt: now)
        probeLogger.info("probe completed: claude=\(probes.claudeAvailable, privacy: .public) codexSDK=\(probes.codexSDKAvailable, privacy: .public) codexCLI=\(probes.codexAvailable, privacy: .public) gemini=\(probes.agentapiLive, privacy: .public) opencode=\(probes.opencodeAvailable, privacy: .public) cursor=\((probes.cursorState.binaryPath != nil), privacy: .public)")
        return response
    }

    /// Convenience for AuthObserver. Maps wire shapes into the actor's
    /// internal override key.
    public static func providerKey(provider: AgentKind, codexBackend: CodexChatBackend?) -> String {
        switch provider {
        case .claude: return "claude"
        case .codex:
            return codexBackend == .sdk ? "codex:sdk" : "codex:cli"
        case .gemini: return "gemini"
        case .opencode: return "opencode"  // PR #29
        case .cursor: return "cursor"
        case .unknown: return "unknown"  // X3 forward-compat key
        }
    }
}

public struct CursorModelProbeState: Sendable {
    public let binaryPath: String?
    public let models: [ModelCatalogEntry]
    public let authenticated: Bool
    public let reason: String?
    public let probedAt: Date
}

public actor CursorModelProbe {
    public static let shared = CursorModelProbe()

    private struct CacheEntry {
        let state: CursorModelProbeState
        let computedAt: Date
    }

    private var cache: CacheEntry?
    private var inflight: Task<CursorModelProbeState, Never>?
    public static let cacheTTL: TimeInterval = 60

    public init() {}

    public func invalidate() {
        cache = nil
        inflight?.cancel()
        inflight = nil
    }

    public func currentModels() async -> [ModelCatalogEntry] {
        await currentState().models
    }

    public func currentState() async -> CursorModelProbeState {
        if let cache,
           Date().timeIntervalSince(cache.computedAt) < Self.cacheTTL {
            return cache.state
        }
        if let task = inflight {
            return await task.value
        }
        let task = Task { await self.runProbe() }
        inflight = task
        let state = await task.value
        cache = CacheEntry(state: state, computedAt: Date())
        inflight = nil
        return state
    }

    private func runProbe() async -> CursorModelProbeState {
        let now = Date()
        guard let binary = AgentSpawner.cursorBinaryPath() else {
            return CursorModelProbeState(
                binaryPath: nil,
                models: [CursorModelCatalog.autoEntry],
                authenticated: false,
                reason: "cursor-agent CLI not on PATH or failed identity check",
                probedAt: now
            )
        }

        let status = try? await ShellRunner.shared.run(
            executable: binary,
            arguments: ["status"],
            timeout: 5
        )
        let statusOutput = ((status?.stdoutString ?? "") + "\n" + (status?.stderrString ?? ""))
            .lowercased()
        let authenticated = status?.exitStatus == 0
            && !statusOutput.contains("not logged in")
            && !statusOutput.contains("not authenticated")
            && !statusOutput.contains("not signed in")

        var models = await probeModels(binary: binary, arguments: ["--list-models"])
        if models.count <= 1 {
            let fallback = await probeModels(binary: binary, arguments: ["models"])
            if fallback.count > models.count {
                models = fallback
            }
        }
        if models.isEmpty {
            models = [CursorModelCatalog.autoEntry]
        }

        let reason: String? = {
            if !authenticated { return "Run cursor-agent login" }
            return nil
        }()

        return CursorModelProbeState(
            binaryPath: binary,
            models: models,
            authenticated: authenticated,
            reason: reason,
            probedAt: now
        )
    }

    private func probeModels(binary: String, arguments: [String]) async -> [ModelCatalogEntry] {
        guard let result = try? await ShellRunner.shared.run(
            executable: binary,
            arguments: arguments,
            timeout: 10
        ) else {
            return [CursorModelCatalog.autoEntry]
        }
        guard result.exitStatus == 0 else {
            return [CursorModelCatalog.autoEntry]
        }
        let output = result.stdoutString.isEmpty
            ? result.stderrString
            : result.stdoutString
        return CursorModelCatalog.parseCLIOutput(output)
    }
}

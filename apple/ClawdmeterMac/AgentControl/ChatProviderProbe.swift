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

    /// Per-provider auth overrides set by AuthObserver. Keyed by
    /// "claude" / "codex" / "gemini" / etc. When present,
    /// the next probe surfaces these values regardless of what the
    /// binary checks say. Cleared when the user re-auths or manually
    /// invalidates the probe.
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
            claudeEnabled: Bool,
            codexEnabled: Bool,
            geminiEnabled: Bool,
            opencodeEnabled: Bool,
            cursorEnabled: Bool,
            grokEnabled: Bool,
            claudeAvailable: Bool,
            codexAvailable: Bool,
            agyHeadlessAvailable: Bool,
            opencodeAvailable: Bool,
            opencodeAuthProviderCount: Int,
            opencodeGoAuthAvailable: Bool,
            openCodeGoModelState: OpenCodeGoModelProbeState,
            cursorState: CursorModelProbeState,
            grokAvailable: Bool
        ) = await Task.detached {
            let claudeEnabled = ProviderEnablement.isEnabled("claude")
            let codexEnabled = ProviderEnablement.isEnabled("codex")
            let geminiEnabled = ProviderEnablement.isEnabled("gemini")
            let opencodeEnabled = ProviderEnablement.isEnabled("opencode")
            let cursorEnabled = ProviderEnablement.isEnabled("cursor")
            let grokEnabled = ProviderEnablement.isEnabled("grok")
            let claudeAvailable = claudeEnabled && ShellRunner.locateBinary("claude") != nil
            let codexAvailable = codexEnabled && ShellRunner.locateBinary("codex") != nil
            // Headless `agy` CLI (Antigravity 2.0) is the DEFAULT Gemini drive path
            // and works with the desktop app CLOSED — binary presence is the signal,
            // mirroring how grok/cursor/codex are probed by `locateBinary`.
            let agyHeadlessAvailable = geminiEnabled && ShellRunner.locateBinary("agy") != nil
            let opencodeBinaryAvailable = await MainActor.run {
                opencodeEnabled && OpencodeProcessManager.shared.locateBinary() != nil
            }
            let opencodeProviderIds = opencodeEnabled
                ? await OpencodeAuthFile.shared.providerIds()
                : []
            let opencodeAuthProviderCount = opencodeProviderIds.count
            // Chat needs a Go API key to route a model through `opencode serve`.
            // Dashboard quota creds (workspace + cookie) alone can't send a
            // prompt, so they must NOT make the chat provider available.
            let opencodeGoAuthAvailable = opencodeEnabled
                && OpenCodeGoCredentials.hasGoAuthFromDisk()
            let opencodeAvailable = opencodeEnabled
                && (opencodeBinaryAvailable || opencodeGoAuthAvailable)
            let disabledOpenCodeGoState = OpenCodeGoModelProbeState(
                models: ModelCatalog.bundled.opencode,
                authenticated: false,
                discoverySucceeded: false,
                reason: "Provider disabled",
                probedAt: Date()
            )
            let openCodeGoModelState = opencodeEnabled
                ? await OpenCodeGoModelProbe.shared.currentState()
                : disabledOpenCodeGoState
            // Passive provider discovery must not launch cursor-agent or
            // touch Cursor's login Keychain item. In dev/AI test builds,
            // those reads can surface SecurityAgent prompts repeatedly
            // because every build may have a new signing requirement.
            let disabledCursorState = CursorModelProbeState(
                binaryPath: nil,
                models: [CursorModelCatalog.autoEntry],
                authenticated: false,
                reason: "Provider disabled",
                probedAt: Date()
            )
            let cursorState = cursorEnabled
                ? await CursorModelProbe.shared.passiveState()
                : disabledCursorState
            let grokAvailable = grokEnabled && ShellRunner.locateBinary("grok") != nil
            return (
                claudeEnabled,
                codexEnabled,
                geminiEnabled,
                opencodeEnabled,
                cursorEnabled,
                grokEnabled,
                claudeAvailable,
                codexAvailable,
                agyHeadlessAvailable,
                opencodeAvailable,
                opencodeAuthProviderCount,
                opencodeGoAuthAvailable,
                openCodeGoModelState,
                cursorState,
                grokAvailable
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
        let (codexAuth, codexReason) = resolveAuth(key: "codex", fallback: probes.codexAvailable)
        // Gemini drives headlessly via `agy` (Antigravity 2.0). The legacy
        // language-server/agentapi drive path is no longer a chat availability
        // fallback.
        let geminiDriveAvailable = probes.agyHeadlessAvailable
        let (geminiAuth, geminiReason) = resolveAuth(key: "gemini", fallback: geminiDriveAvailable)
        let (opencodeAuth, opencodeReason) = resolveAuth(
            key: "opencode",
            fallback: probes.opencodeGoAuthAvailable
                && probes.openCodeGoModelState.discoverySucceeded
        )
        let (cursorAuth, cursorReason) = resolveAuth(
            key: "cursor",
            fallback: probes.cursorState.authenticated
        )
        let (grokAuth, grokReason) = resolveAuth(key: "grok", fallback: probes.grokAvailable)
        let opencodeDefaultReason: String? = {
            if !probes.opencodeEnabled { return "Provider disabled" }
            if !probes.opencodeGoAuthAvailable {
                return "Add your OpenCode Go API key in Settings"
            }
            if !probes.openCodeGoModelState.discoverySucceeded {
                return probes.openCodeGoModelState.reason ?? "OpenCode Go model discovery failed"
            }
            return nil
        }()

        let entries = [
            ChatProviderEntry(
                provider: .claude,
                available: probes.claudeAvailable,
                authenticated: claudeAuth,
                capabilityProbePassed: probes.claudeAvailable && claudeAuth,
                lastProbedAt: now,
                reason: claudeReason ?? (probes.claudeAvailable ? nil : (probes.claudeEnabled ? "claude CLI not on PATH" : "Provider disabled"))
            ),
            ChatProviderEntry(
                provider: .codex,
                available: probes.codexAvailable,
                authenticated: codexAuth,
                capabilityProbePassed: probes.codexAvailable && codexAuth,
                lastProbedAt: now,
                reason: codexReason ?? (probes.codexAvailable ? nil : (probes.codexEnabled ? "codex CLI not on PATH — run `codex login`." : "Provider disabled"))
            ),
            ChatProviderEntry(
                provider: .gemini,
                available: geminiDriveAvailable,
                authenticated: geminiAuth,
                capabilityProbePassed: geminiDriveAvailable && geminiAuth,
                lastProbedAt: now,
                reason: geminiReason ?? (geminiDriveAvailable ? nil : (probes.geminiEnabled ? "Install the agy CLI (Antigravity 2) — or open the Antigravity app" : "Provider disabled"))
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
            ChatProviderEntry(
                provider: .grok,
                available: probes.grokAvailable,
                authenticated: grokAuth,
                capabilityProbePassed: probes.grokAvailable && grokAuth,
                lastProbedAt: now,
                reason: grokReason ?? (probes.grokAvailable ? nil : (probes.grokEnabled ? "grok binary not on PATH" : "Provider disabled"))
            ),
        ].filter { ProviderRegistry.isEnabled(agentKind: $0.provider) }
        let response = ChatProvidersResponse(
            providers: entries,
            enabledProviderIDs: ProviderEnablement.enabledProviderIDs(for: .chat)
        )
        cache = CacheEntry(response: response, computedAt: now)
        probeLogger.info("probe completed: claude=\(probes.claudeAvailable, privacy: .public) codex=\(probes.codexAvailable, privacy: .public) geminiAgy=\(probes.agyHeadlessAvailable, privacy: .public) opencode=\(probes.opencodeAvailable, privacy: .public) cursor=\((probes.cursorState.binaryPath != nil), privacy: .public)")
        return response
    }

    /// Convenience for AuthObserver. Maps wire shapes into the actor's
    /// internal override key.
    public static func providerKey(provider: AgentKind, codexBackend: CodexChatBackend?) -> String {
        switch provider {
        case .claude: return "claude"
        case .codex:
            return "codex"
        case .gemini: return "gemini"
        case .opencode: return "opencode"  // PR #29
        case .cursor: return "cursor"
        case .grok: return "grok"  // wire v26 (ACP)
        case .unknown: return "unknown"  // X3 forward-compat key
        }
    }
}

public struct OpenRouterModelProbeState: Sendable {
    public let models: [ModelCatalogEntry]
    public let authenticated: Bool
    public let discoverySucceeded: Bool
    public let reason: String?
    public let probedAt: Date
}

public actor OpenRouterModelProbe {
    public static let shared = OpenRouterModelProbe()

    private struct CacheEntry {
        let state: OpenRouterModelProbeState
        let computedAt: Date
    }

    private struct ModelsResponse: Decodable {
        let data: [Model]
    }

    private struct Model: Decodable {
        let id: String
        let name: String?
        let contextLength: Int?
        let supportedParameters: [String]?

        private enum CodingKeys: String, CodingKey {
            case id
            case name
            case contextLength = "context_length"
            case supportedParameters = "supported_parameters"
        }
    }

    private var cache: CacheEntry?
    private var inflight: Task<OpenRouterModelProbeState, Never>?
    public static let cacheTTL: TimeInterval = 60
    private static let endpoint = URL(string: "https://openrouter.ai/api/v1/models?output_modalities=text")!

    public init() {}

    public func invalidate() {
        cache = nil
        inflight?.cancel()
        inflight = nil
    }

    public func currentModels() async -> [ModelCatalogEntry] {
        await currentState().models
    }

    public func currentState() async -> OpenRouterModelProbeState {
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

    private func runProbe() async -> OpenRouterModelProbeState {
        let now = Date()
        let environmentKey = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fileKey = environmentKey?.isEmpty != false
            ? await OpencodeAuthFile.shared.apiKey(providerId: "openrouter")
            : nil
        let key = environmentKey?.isEmpty == false ? environmentKey : fileKey
        guard let key, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return OpenRouterModelProbeState(
                models: ModelCatalog.bundled.opencode,
                authenticated: false,
                discoverySucceeded: false,
                reason: "Add an OpenRouter key in Settings",
                probedAt: now
            )
        }

        var request = URLRequest(url: Self.endpoint)
        request.timeoutInterval = 8
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                return OpenRouterModelProbeState(
                    models: ModelCatalog.bundled.opencode,
                    authenticated: true,
                    discoverySucceeded: false,
                    reason: "OpenRouter model discovery failed with HTTP \(status)",
                    probedAt: now
                )
            }
            let models = try Self.parseModelsResponse(data)
            guard !models.isEmpty else {
                return OpenRouterModelProbeState(
                    models: ModelCatalog.bundled.opencode,
                    authenticated: true,
                    discoverySucceeded: false,
                    reason: "OpenRouter returned no text models",
                    probedAt: now
                )
            }
            return OpenRouterModelProbeState(
                models: models,
                authenticated: true,
                discoverySucceeded: true,
                reason: nil,
                probedAt: now
            )
        } catch {
            return OpenRouterModelProbeState(
                models: ModelCatalog.bundled.opencode,
                authenticated: true,
                discoverySucceeded: false,
                reason: "OpenRouter model discovery failed: \(error.localizedDescription)",
                probedAt: now
            )
        }
    }

    internal static func parseModelsResponse(_ data: Data) throws -> [ModelCatalogEntry] {
        let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
        let entries = decoded.data.compactMap { model -> ModelCatalogEntry? in
            let id = model.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { return nil }
            let parameters = Set((model.supportedParameters ?? []).map { $0.lowercased() })
            let supportsReasoning = parameters.contains("reasoning") || parameters.contains("include_reasoning")
            let supportsEffort = supportsReasoning
            let displayName = model.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let bundled = ModelCatalog.bundled.opencode.first(where: { $0.id == id })
            return ModelCatalogEntry(
                id: id,
                provider: .opencode,
                displayName: "OpenRouter · \((displayName?.isEmpty == false ? displayName : nil) ?? id)",
                cliAlias: nil,
                supportsThinking: supportsReasoning,
                supportsEffort: supportsEffort,
                contextWindow: model.contextLength,
                recommendedFor: bundled?.recommendedFor,
                badge: bundled?.badge
            )
        }
        return featuredFirst(entries)
    }

    private static func featuredFirst(_ entries: [ModelCatalogEntry]) -> [ModelCatalogEntry] {
        var byId = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        var ordered: [ModelCatalogEntry] = []
        for featured in ModelCatalog.bundled.opencode {
            if let entry = byId.removeValue(forKey: featured.id) {
                ordered.append(entry)
            }
        }
        ordered.append(contentsOf: byId.values.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        })
        return ordered
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

    public func passiveState() async -> CursorModelProbeState {
        let now = Date()
        let binary = ShellRunner.locateBinary("cursor-agent") ?? ShellRunner.locateBinary("agent")
        let authenticated = await CursorAuthProbeCLI.isAuthenticated(binary: binary)
        let reason: String? = {
            if binary == nil { return "cursor-agent CLI not on PATH" }
            if !authenticated { return "Run cursor-agent login" }
            return nil
        }()
        return CursorModelProbeState(
            binaryPath: binary,
            models: [CursorModelCatalog.autoEntry],
            authenticated: authenticated,
            reason: reason,
            probedAt: now
        )
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
        let statusOutput = (status?.stdoutString ?? "") + "\n" + (status?.stderrString ?? "")
        let cliAuthenticated = status?.exitStatus == 0
            && CursorAuthProbe.isStatusOutputAuthenticated(statusOutput)
        let authenticated = CursorAuthProbe.hasPassiveAuthentication()
            || cliAuthenticated

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

/// Mac-only Cursor auth probe that can run `cursor-agent status` via
/// `ShellRunner`. Keeps subprocess spawning out of ClawdmeterShared.
enum CursorAuthProbeCLI {

    static func isCLIStatusAuthenticated(binary: String) async -> Bool {
        guard let result = try? await ShellRunner.shared.run(
            executable: binary,
            arguments: ["status"],
            timeout: 5
        ) else { return false }
        guard result.exitStatus == 0 else { return false }
        let output = result.stdoutString + "\n" + result.stderrString
        return CursorAuthProbe.isStatusOutputAuthenticated(output)
    }

    static func isAuthenticated(binary: String?) async -> Bool {
        if CursorAuthProbe.hasPassiveAuthentication() {
            return true
        }
        guard let binary else { return false }
        return await isCLIStatusAuthenticated(binary: binary)
    }
}

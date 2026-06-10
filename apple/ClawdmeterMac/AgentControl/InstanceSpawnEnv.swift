import Foundation
import OSLog
import ClawdmeterShared

private let instanceSpawnLogger = Logger(subsystem: "com.clawdmeter.mac", category: "InstanceSpawnEnv")

/// Process-wide resolver from a session's pinned `providerInstanceId`
/// to the spawn-env pieces (config-dir var + per-instance secrets).
///
/// Wired once by `AppRuntime` at boot (`attach`). Unattached (tests,
/// pre-boot), nil/primary pins resolve to the primary instance; any
/// SECONDARY pin fails closed (`.unknown`) — there is no registry to
/// vouch for it.
///
/// **Unknown or non-isolatable pins fail closed.** A session pinned to
/// an account the registry no longer carries (user removed it in
/// Settings), OR to an instance that can't actually be config-isolated
/// (no config-dir var for its kind, or an empty config root — possible
/// only via a hand-edited provider-instances.json), must NOT silently
/// fall back to the primary — that would bill a different subscription
/// than the user picked. Callers surface a clean error.
enum InstanceSpawnEnv {

    private static let lock = NSLock()
    private static var _registry: ProviderInstanceRegistry?

    static func attach(_ registry: ProviderInstanceRegistry) {
        lock.lock(); defer { lock.unlock() }
        _registry = registry
    }

    /// Test hook: restore the unattached default so suites that attach a
    /// registry don't leak it into later test classes (the resolver is
    /// process-global). Production never detaches.
    static func detachForTesting() {
        lock.lock(); defer { lock.unlock() }
        _registry = nil
        _claudeTokenLookup = nil
    }

    /// Claude-secondary token lookup. Defaults to the per-instance
    /// Keychain partition; tests inject a stub so the resolver's
    /// token-required gate is exercisable without a real Keychain.
    private static var _claudeTokenLookup: ((ProviderInstanceId) -> String?)?

    static func setClaudeTokenLookupForTesting(_ lookup: @escaping (ProviderInstanceId) -> String?) {
        lock.lock(); defer { lock.unlock() }
        _claudeTokenLookup = lookup
    }

    private static func claudeToken(for instance: ProviderInstanceId) -> String? {
        lock.lock()
        let lookup = _claudeTokenLookup
        lock.unlock()
        if let lookup { return lookup(instance) }
        return PastedAnthropicTokenProvider.forInstance(instance).currentAccessToken
    }

    static var registry: ProviderInstanceRegistry? {
        lock.lock(); defer { lock.unlock() }
        return _registry
    }

    enum Resolution {
        case resolved(ProviderInstanceId, secrets: [String: String])
        /// Pinned wireId is not registered — fail closed.
        case unknown(wireId: String)
    }

    /// Resolve a pinned wireId for `agent`. nil / primary wireIds resolve
    /// to the primary instance with no secrets.
    static func resolve(wireId: String?, agent: AgentKind) async -> Resolution {
        let primary = ProviderInstanceId.primary(kind: agent)
        guard let wireId, !wireId.isEmpty, wireId != primary.wireId else {
            return .resolved(primary, secrets: [:])
        }
        guard let registry,
              let instance = await registry.lookup(wireId: wireId),
              instance.kind == agent else {
            return .unknown(wireId: wireId)
        }
        // A secondary that can't be config-isolated would silently spawn
        // against the PRIMARY account's real config (scrub runs, but no
        // isolation var gets set). Refuse instead — only reachable via a
        // hand-edited store, but the failure mode is wrong-account
        // billing under a "work" label.
        guard let root = instance.configRoot, !root.isEmpty,
              ProviderInstanceEnvironment.configDirVariable(for: instance.kind) != nil else {
            return .unknown(wireId: wireId)
        }
        let secrets = secrets(for: instance)
        // Claude secondaries MUST carry their token. CLAUDE_CONFIG_DIR
        // relocates config files, but Claude Code's Keychain item is
        // per-OS-user — a token-less spawn under an empty config dir
        // falls back to the PRIMARY's Keychain login and silently bills
        // the default subscription under a "work" label. Fail closed
        // (re-authenticate in Settings) instead.
        if instance.kind == .claude, secrets["CLAUDE_CODE_OAUTH_TOKEN"] == nil {
            instanceSpawnLogger.error(
                "resolve: \(wireId, privacy: .public) has no stored token — refusing spawn (re-authenticate in Settings)"
            )
            return .unknown(wireId: wireId)
        }
        return .resolved(instance, secrets: secrets)
    }

    static func resolve(for session: AgentSession) async -> Resolution {
        await resolve(wireId: session.providerInstanceId, agent: session.agent)
    }

    /// True when `wireId` is spawnable for `agent` — nil/primary, or a
    /// registered instance of the same kind. Create handlers validate
    /// with this BEFORE persisting a session that could never spawn.
    static func isSpawnable(wireId: String?, agent: AgentKind) async -> Bool {
        if case .resolved = await resolve(wireId: wireId, agent: agent) { return true }
        return false
    }

    /// Per-instance credential env. Claude secondaries inject the
    /// subscription OAuth token captured at add-account time
    /// (`CLAUDE_CODE_OAUTH_TOKEN` — survives both env scrubs by design,
    /// see `ClaudeSpawnEnvTests.testPreservesClaudeCodeOAuthToken`).
    /// Codex needs none: its auth.json lives under the instance's
    /// `CODEX_HOME`.
    static func secrets(for instance: ProviderInstanceId) -> [String: String] {
        guard !instance.isPrimary else { return [:] }
        switch instance.kind {
        case .claude:
            if let token = claudeToken(for: instance), !token.isEmpty {
                return ["CLAUDE_CODE_OAUTH_TOKEN": token]
            }
            return [:]
        default:
            return [:]
        }
    }

    /// Claude PTY env for `session`, layered with the managed repo env.
    /// nil ⇒ the pinned account is gone (fail closed; see type doc).
    static func claudeEnv(
        for session: AgentSession,
        extra: [String: String]? = nil
    ) async -> [String: String]? {
        switch await resolve(for: session) {
        case .resolved(let instance, let secrets):
            return AgentSpawner.claudePtyEnv(extra: extra, instance: instance, secrets: secrets)
        case .unknown(let wireId):
            instanceSpawnLogger.error(
                "claudeEnv: session \(session.id.uuidString, privacy: .public) pins unregistered instance \(wireId, privacy: .public) — refusing spawn"
            )
            return nil
        }
    }

    /// Overlay the instance config-dir isolation onto an already-built
    /// harness child env (Codex app-server). Returns nil for unknown
    /// pins, `base` unchanged for the primary.
    static func harnessEnv(
        base: [String: String],
        wireId: String?,
        agent: AgentKind
    ) async -> [String: String]? {
        switch await resolve(wireId: wireId, agent: agent) {
        case .resolved(let instance, let secrets):
            guard !instance.isPrimary || !secrets.isEmpty else { return base }
            return ProviderInstanceEnvironment.buildEnv(
                for: instance, parentEnv: base, secrets: secrets
            )
        case .unknown(let wireId):
            instanceSpawnLogger.error(
                "harnessEnv: unregistered instance \(wireId, privacy: .public) — refusing spawn"
            )
            return nil
        }
    }
}

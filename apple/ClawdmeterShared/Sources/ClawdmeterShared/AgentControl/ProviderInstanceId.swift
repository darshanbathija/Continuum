import Foundation

/// Configured-instance identifier — splits **provider kind** (claude /
/// codex / gemini / opencode / cursor — `AgentKind`) from **configured
/// instance** (claude_personal vs claude_work; codex_pro vs codex_oss).
///
/// **F3 (Phase 1; D23 strangler-fig completion + Agent 1 plan #8 +
/// promotes deferred D4).** Each instance owns:
///   - a `kind` (the provider family)
///   - a stable `name` ("personal", "work", "pro", "oss"; user-defined)
///   - an optional `homePathOverride` for per-instance config isolation
///     (e.g. `~/.claude-personal/` vs `~/.claude-work/`)
///   - an optional `keychainAccessGroupOverride` so each instance can
///     scope its credential entries separately (codex #10 security hook)
///
/// **Codex eng-review #10 (HOME isolation is security-critical):** this
/// type carries the SHAPE; the daemon-side wire-up PR (F3-wire) enforces
/// the security invariants:
///   - Keychain partitioning by instance (per-instance access group)
///   - Env scrubbing when spawning per-instance child processes
///     (no `CLAUDE_*` env from instance A leaks into instance B's spawn)
///   - Credential bleed tests (integration test confirming a leaked-key
///     scenario for instance A doesn't expose instance B's creds)
///   - Log redaction (per-instance prefixes; never log the raw
///     `homePathOverride` value unscrubbed)
///
/// This source-only PR is the foundation. The wire bump (mobile protocol
/// gains a `providerInstanceId` field gated to `wireVersion ≥ 21`) and
/// daemon wire-up land in F3-wire.
///
/// **Back-compat:** every existing call site assumes one instance per
/// provider. `ProviderInstanceId.primary(kind:)` returns the synthesized
/// default for that kind so non-multi-account code continues to work
/// without modification.
///
/// **Plan:** F3 (Phase 1; D23 / Agent 1 plan #8 / promoted D4) — see
/// `.claude/plans/study-this-codebase-crystalline-shore.md`.
public struct ProviderInstanceId: Hashable, Codable, Sendable {

    /// Provider family this instance belongs to.
    public let kind: AgentKind

    /// User-visible instance name. Stable across app launches.
    /// Convention: lowercase ASCII slug ("personal", "work", "pro",
    /// "oss"). The `primary` sentinel is "__primary__" — the back-compat
    /// default that maps to the existing single-instance behavior.
    public let name: String

    /// Optional per-instance HOME override. When non-nil, the daemon
    /// spawns child processes with `HOME=<override>` so provider configs
    /// (~/.claude/, ~/.codex/, etc.) stay isolated per instance.
    /// `nil` ⇒ inherit the OS user's real HOME (the "primary" default).
    public let homePathOverride: String?

    /// Optional Keychain access-group override so each instance's
    /// credentials live under a distinct partition. `nil` ⇒ shared
    /// access group (the "primary" default). Codex #10 security hook —
    /// the daemon F3-wire PR enforces this.
    public let keychainAccessGroupOverride: String?

    public init(
        kind: AgentKind,
        name: String,
        homePathOverride: String? = nil,
        keychainAccessGroupOverride: String? = nil
    ) {
        self.kind = kind
        self.name = name
        self.homePathOverride = homePathOverride
        self.keychainAccessGroupOverride = keychainAccessGroupOverride
    }

    // MARK: - Sentinels

    /// Back-compat default: one synthesized instance per provider kind.
    /// Every pre-F3 call site that knows only `AgentKind` resolves to
    /// this when asked for its instance.
    public static func primary(kind: AgentKind) -> ProviderInstanceId {
        ProviderInstanceId(
            kind: kind,
            name: Self.primaryName,
            homePathOverride: nil,
            keychainAccessGroupOverride: nil
        )
    }

    /// Stable sentinel name for the primary instance. Used by mobile
    /// protocol fields (wire ≥ 21) — clients on older wires see only
    /// the primary instance.
    public static let primaryName = "__primary__"

    /// Is this the back-compat primary instance for its kind?
    public var isPrimary: Bool {
        name == Self.primaryName
            && homePathOverride == nil
            && keychainAccessGroupOverride == nil
    }

    // MARK: - Stable wire id

    /// `kind.rawValue` + `/` + `name`. Stable across launches; used as
    /// the wire serialization + the orchestration command store's
    /// per-instance partition key.
    public var wireId: String {
        "\(kind.rawValue)/\(name)"
    }
}

/// In-memory registry of configured provider instances. Holds the
/// canonical set of instances the user has defined + handles
/// primary-instance fallback for non-multi-account code.
///
/// **Wire-up is F3-wire (follow-up).** This source-only PR provides the
/// registry primitive; the daemon-side `AppRuntime` integration (which
/// makes each `AppModel` instance-aware) lands in F3-wire.
///
/// **Thread-safety:** `actor` so daemon-side mutations (add/remove
/// instance) and consumer reads (list instances for a given kind) are
/// race-free. Snapshot reads return value types so callers don't see
/// torn state mid-mutation.
public actor ProviderInstanceRegistry {

    private var instances: [String: ProviderInstanceId] = [:]

    public init() {
        // Seed with the primary instance for every known AgentKind so
        // pre-F3 callers always find a default.
        for kind in AgentKind.allCases {
            let primary = ProviderInstanceId.primary(kind: kind)
            instances[primary.wireId] = primary
        }
    }

    /// Register or replace an instance. Returns the inserted record.
    @discardableResult
    public func upsert(_ instance: ProviderInstanceId) -> ProviderInstanceId {
        instances[instance.wireId] = instance
        return instance
    }

    /// Remove an instance by wireId. The primary instance for a kind
    /// CANNOT be removed — that would break back-compat callers. Attempts
    /// to remove the primary are no-ops.
    public func remove(wireId: String) {
        guard let instance = instances[wireId], !instance.isPrimary else { return }
        instances.removeValue(forKey: wireId)
    }

    /// All instances for a given kind. Always at least one (the primary).
    public func instances(for kind: AgentKind) -> [ProviderInstanceId] {
        instances.values
            .filter { $0.kind == kind }
            .sorted { (a, b) in
                // Primary first, then alphabetical by name.
                if a.isPrimary { return true }
                if b.isPrimary { return false }
                return a.name < b.name
            }
    }

    /// Snapshot of every registered instance, sorted by wireId.
    public func allInstances() -> [ProviderInstanceId] {
        instances.values.sorted { $0.wireId < $1.wireId }
    }

    /// Lookup by wireId. Returns nil if not registered.
    public func lookup(wireId: String) -> ProviderInstanceId? {
        instances[wireId]
    }
}

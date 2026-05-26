// FeatureFlags — minimal env/UserDefaults-backed flag registry.
//
// Why minimal? Phase 1 (F1) introduced the strangler-fig pattern: provider
// adapters land behind a flag so legacy + canonical coexist mid-migration.
// F2 (orchestration event store) needs the same: ship the SQLite log + replay
// path next to the existing `sessions.json` snapshot path, but let the
// daemon choose at boot whether to seed registry state from event replay
// (new) or the JSON snapshot (legacy). F3 (provider instance registry) and
// the F1*-wire follow-ups all use this same gating convention. One-line
// flip when we cut over.
//
// Resolution order (first-wins):
//   1. Test override (per-flag; only honored when set)
//   2. Process environment (`CLAWDMETER_FF_<NAME>=1|0|true|false|yes|no`)
//   3. UserDefaults (`com.clawdmeter.featureFlags.<name>`)
//   4. Compiled-in default.
//
// Env lets CI / shell scripts force a value without mutating user prefs.
// UserDefaults lets the in-app settings panel toggle without a relaunch.
// The compiled default is the safe rollback target (legacy behavior).
//
// All flags here MUST default to the legacy behavior so A/B rollback is a
// matter of flipping the default back to `false` and rebuilding.

import Foundation

/// Namespace for feature-flag lookups. Pure stateless utility — no global
/// mutable state of its own (beyond per-flag test overrides); UserDefaults
/// is the persistent store, env is the override path.
public enum FeatureFlags {

    // MARK: - Provider adapter strangler-fig (F1)

    /// When ON, the Claude branch in `SessionChatStore` (chat) and
    /// `UsageHistoryLoader` (analytics) routes raw Claude JSONL through
    /// `ClaudeAdapter.translate(...)` → canonical `ProviderRuntimeEvent`s,
    /// then materializes downstream values (`ParsedLine`, `UsageRecord`)
    /// from those events. When OFF, both call sites use their original
    /// in-line parsers — the pre-F1 path.
    ///
    /// Parity is the gating contract: with the flag in either state, the
    /// downstream `[AgentMessage]` / `[UsageRecord]` arrays produced by a
    /// fixed JSONL input must be identical. The F1aWireParityTests suite
    /// enforces this for every fixture shape we ship.
    ///
    /// **Default: OFF.** Flip to ON in F1-finalize after all 5 provider
    /// wires (F1a-wire through F1e-wire) have shipped and parity has
    /// held on real session data.
    ///
    /// **Override (env):** `CLAWDMETER_USE_CLAUDE_ADAPTER=1`
    /// **Override (test):** set `useClaudeAdapterOverride` (auto-cleared
    /// in tests' `tearDown`).
    public static var useClaudeAdapter: Bool {
        if let override = useClaudeAdapterOverride { return override }
        return resolve(envName: "CLAWDMETER_USE_CLAUDE_ADAPTER",
                       userDefaultsKey: "com.clawdmeter.featureFlags.useClaudeAdapter",
                       default: false)
    }

    /// F1b-wire sibling of `useClaudeAdapter` for the Codex provider.
    /// When ON, the Codex branch in `SessionChatStore` (chat) and
    /// `UsageHistoryLoader` (analytics) routes raw Codex JSONL through
    /// `CodexAdapter.translate(...)` → canonical `ProviderRuntimeEvent`s.
    ///
    /// Unlike Claude's adapter, `CodexAdapter` is **stateful** —
    /// cumulative→delta token math + running `currentCwd` / `currentModel`
    /// must survive across `translate(line:)` calls within a session.
    /// The wire owns the per-session lifetime: one adapter per file
    /// (analytics) / per `response_item` line (chat — `response_item`
    /// itself is stateless for the adapter, but the bridge constructs a
    /// fresh adapter per call to keep the contract uniform).
    ///
    /// Parity contract enforced by `F1bParityTests`.
    /// Default OFF; flipped in F1-finalize after all 5 wires merge.
    public static var useCodexAdapter: Bool {
        if let override = useCodexAdapterOverride { return override }
        return resolve(envName: "CLAWDMETER_USE_CODEX_ADAPTER",
                       userDefaultsKey: "com.clawdmeter.featureFlags.useCodexAdapter",
                       default: false)
    }

    /// F1c-wire sibling for OpenCode. When ON, `OpencodeSSEAdapter` (chat)
    /// and `OpencodeUsageParser` (analytics) route through
    /// `OpenCodeAdapter.translate(...)` → canonical events. Stateless
    /// adapter, so the bridge is line-level not file-level.
    ///
    /// Parity contract enforced by `F1cWireParityTests` +
    /// `F1cWireChatParityTests`. Default OFF; flipped in F1-finalize.
    public static var useOpenCodeAdapter: Bool {
        if let override = useOpenCodeAdapterOverride { return override }
        return resolve(envName: "CLAWDMETER_USE_OPENCODE_ADAPTER",
                       userDefaultsKey: "com.clawdmeter.featureFlags.useOpenCodeAdapter",
                       default: false)
    }

    /// F1e-wire sibling for Antigravity. When ON, the Antigravity branch
    /// in `UsageHistoryLoader` (analytics) routes the per-conversation
    /// rollup through `AntigravityAdapter.translate(...)` → canonical
    /// `ProviderRuntimeEvent`, then materializes the downstream
    /// `UsageRecord` from that event. When OFF, the loader emits the
    /// legacy `UsageRecord` produced by `AntigravityUsageParser.parse(...)`
    /// directly — the pre-F1 path.
    ///
    /// Antigravity has two on-disk formats — `.db` (Antigravity 2.0.6+,
    /// macOS/iOS only — gated by `AntigravityDBUsageParser`'s
    /// `#if os(macOS) || os(iOS)`) and `.pb` (encrypted legacy archive,
    /// cross-platform byte-÷-4 estimator). The wire calls the matching
    /// `AntigravityAdapter.translate(...)` overload — `dbUsage:` on
    /// macOS/iOS (same guard as the adapter's `.db` overload) and
    /// `legacyRecord:` everywhere. watchOS keeps the legacy byte
    /// estimator regardless of the flag because the `.db` overload
    /// doesn't compile there (see PR #154's guard fix).
    ///
    /// Parity is the gating contract: with the flag in either state, the
    /// downstream `[UsageRecord]` arrays produced by a fixed Antigravity
    /// conversation directory must be identical. The F1eParityTests
    /// suite enforces this for every fixture shape the legacy parser
    /// tolerates.
    ///
    /// **Default: OFF.** Flip to ON in F1-finalize after all 5 provider
    /// wires (F1a-wire through F1e-wire) have shipped and parity has
    /// held on real session data.
    ///
    /// **Override (env):** `CLAWDMETER_USE_ANTIGRAVITY_ADAPTER=1`
    /// **Override (test):** set `useAntigravityAdapterOverride` (auto-cleared
    /// in tests' `tearDown`).
    public static var useAntigravityAdapter: Bool {
        if let override = useAntigravityAdapterOverride { return override }
        return resolve(envName: "CLAWDMETER_USE_ANTIGRAVITY_ADAPTER",
                       userDefaultsKey: "com.clawdmeter.featureFlags.useAntigravityAdapter",
                       default: false)
    }

    // MARK: - Orchestration event store (F2)

    /// F2 — Orchestration event store with append-only events + WAL +
    /// replay. When true, `AgentSessionRegistry.init` seeds itself by
    /// replaying the event log; every mutation writes a receipt to the
    /// log before the in-memory state changes. When false (default),
    /// the registry uses the legacy `sessions.json` snapshot path
    /// unchanged.
    ///
    /// Default `false` — F2 lands as opt-in. Wire-up PR (`F2-wire`)
    /// flips the default to `true` once parity is verified on real
    /// session data.
    public static var orchestrationEventStore: Bool {
        resolve(envName: "CLAWDMETER_FF_ORCHESTRATION_EVENT_STORE",
                userDefaultsKey: "com.clawdmeter.featureFlags.orchestrationEventStore",
                default: false)
    }

    // MARK: - Test hooks

    /// Per-call override seen by `useClaudeAdapter`. Test cases set this
    /// to force the wired path regardless of the host environment. Reset
    /// to `nil` after each test (use `defer`).
    nonisolated(unsafe) public static var useClaudeAdapterOverride: Bool?

    /// Per-call override seen by `useCodexAdapter`. Test cases set this
    /// to force the wired path regardless of the host environment. Reset
    /// to `nil` after each test (use `defer`).
    nonisolated(unsafe) public static var useCodexAdapterOverride: Bool?

    /// Per-call override seen by `useOpenCodeAdapter`. Test cases set this
    /// to force the wired path regardless of the host environment. Reset
    /// to `nil` after each test (use `defer`).
    nonisolated(unsafe) public static var useOpenCodeAdapterOverride: Bool?

    /// Per-call override seen by `useAntigravityAdapter`. Test cases set
    /// this to force the wired path regardless of the host environment.
    /// Reset to `nil` after each test (use `defer`).
    nonisolated(unsafe) public static var useAntigravityAdapterOverride: Bool?

    // MARK: - Resolution

    /// Reads `name` from the process environment + interprets it as a
    /// truthy/falsy string. Returns nil when unset or unparseable.
    /// Exposed `internal` for tests.
    static func envBool(_ name: String) -> Bool? {
        guard let raw = ProcessInfo.processInfo.environment[name] else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch trimmed {
        case "1", "true", "yes", "on", "y", "t": return true
        case "0", "false", "no", "off", "n", "f": return false
        default: return nil
        }
    }

    private static func resolve(envName: String, userDefaultsKey: String, default defaultValue: Bool) -> Bool {
        if let env = envBool(envName) { return env }
        if let ud = UserDefaults.standard.object(forKey: userDefaultsKey) as? Bool { return ud }
        return defaultValue
    }
}

// FeatureFlags — minimal env/UserDefaults-backed flag registry.
//
// Why minimal? Phase 1 (F1) introduced the strangler-fig pattern: provider
// adapters land behind a flag so legacy + canonical coexist mid-migration.
// F2 (orchestration event store) needs the same: ship the SQLite log + replay
// path next to the existing `sessions.json` snapshot path, but let the
// daemon choose at boot whether to seed registry state from event replay
// (new) or the JSON snapshot (legacy). One-line flip when we cut over.
//
// Resolution order (first-wins):
//   1. Process environment (`CLAWDMETER_FF_<NAME>=1|0|true|false|yes|no`)
//   2. UserDefaults (`com.clawdmeter.featureFlags.<name>`)
//   3. Compiled-in default.
//
// Env lets CI / shell scripts force a value without mutating user prefs.
// UserDefaults lets the in-app settings panel toggle without a relaunch.
// The compiled default is the safe rollback target (legacy behavior).
//
// All flags here MUST default to the legacy behavior so A/B rollback is a
// matter of flipping the default back to `false` and rebuilding.

import Foundation

/// Namespace for feature-flag lookups. Pure stateless utility — no global
/// mutable state of its own; UserDefaults is the persistent store, env is
/// the override path.
public enum FeatureFlags {

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

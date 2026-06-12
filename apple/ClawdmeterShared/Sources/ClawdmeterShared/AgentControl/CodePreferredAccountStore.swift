import Foundation

/// Per-provider default account for new Code-tab sessions. Distinct from
/// Chat's per-vendor account pin (`ChatV2Store.selectedAccountByVendor`) —
/// this only seeds the Code empty-state / draft composers and the Settings
/// provider account list.
public enum CodePreferredAccountStore: Sendable {

    private static let defaultsKey = "clawdmeter.code.preferredAccountWireIdByKind"

    /// Stored preferred wireId for `kind`. `nil` means the back-compat
    /// primary instance (`claude/__primary__`, `codex/__primary__`).
    public static func preferredWireId(for kind: AgentKind) -> String? {
        let map = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
        guard let raw = map[kind.rawValue] else { return nil }
        return raw.isEmpty ? nil : raw
    }

    /// Persist the preferred account. Pass `nil` (or a primary wireId) to
    /// prefer the default Claude Code / ~/.codex account.
    public static func setPreferred(wireId: String?, for kind: AgentKind) {
        var map = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
        if let wireId, ProviderInstanceId.isSecondaryWireId(wireId) {
            map[kind.rawValue] = wireId
        } else {
            map[kind.rawValue] = ""
        }
        UserDefaults.standard.set(map, forKey: defaultsKey)
    }

    /// Whether `instance` is the configured Code default for its kind.
    /// When nothing is stored yet, the primary instance is preferred.
    public static func isPreferred(_ instance: ProviderInstanceId) -> Bool {
        let stored = preferredWireId(for: instance.kind)
        if let stored {
            return instance.wireId == stored
        }
        return instance.isPrimary
    }

    /// Spawn-time `providerInstanceId` for Code: `nil` for the primary
    /// account, else the pinned secondary wireId. Stale pins fall back to
    /// primary.
    public static func providerInstanceId(
        for kind: AgentKind,
        available: [ProviderInstanceId]
    ) -> String? {
        guard let preferred = preferredWireId(for: kind) else { return nil }
        guard available.contains(where: { $0.wireId == preferred }) else { return nil }
        return preferred
    }
}

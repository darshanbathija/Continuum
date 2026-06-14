import Foundation
import ClawdmeterShared

/// Single source for the Spawn-mode preference keys + defaults shared by the
/// Settings → Spawn pane (writes), the Code-sidebar Spawn button (visibility +
/// gear deep-link), and `SpawnConfigSheet` (seed count + agent). Centralizing
/// the `@AppStorage` keys here keeps the three call sites from drifting.
enum SpawnSettings {
    /// Whether the Spawn button shows in the Code sidebar. Already-open spawn
    /// groups keep rendering regardless, so hiding the button never orphans a
    /// running batch.
    static let showButtonKey = "clawdmeter.spawn.showButton"
    /// Pre-selected session count when opening a fresh spawn config sheet.
    /// Stored as one of `SpawnPlan.sessionCountOptions`.
    static let defaultSessionCountKey = "clawdmeter.spawn.defaultSessionCount"
    /// Pre-selected agent ("model") seeded into a fresh spawn allocation.
    /// Stored as an `AgentKind.rawValue`; falls back to the first spawnable
    /// agent when the stored choice isn't installed/enabled.
    static let defaultAgentKey = "clawdmeter.spawn.defaultAgent"

    static let showButtonDefault = true
    static let defaultSessionCountDefault = SpawnPlan.sessionCountOptions[0]
    static let defaultAgentDefault = AgentKind.claude.rawValue

    /// Clamp a stored session count back onto the offered options so a stale
    /// or hand-edited value can't render an out-of-range selection.
    static func sanitizedSessionCount(_ raw: Int) -> Int {
        SpawnPlan.sessionCountOptions.contains(raw) ? raw : defaultSessionCountDefault
    }

    /// Resolve the stored agent rawValue to a selectable `AgentKind`.
    static func sanitizedAgent(_ raw: String) -> AgentKind {
        guard let kind = AgentKind(rawValue: raw),
              SpawnPlan.selectableAgents.contains(kind) else {
            return AgentKind(rawValue: defaultAgentDefault) ?? .claude
        }
        return kind
    }
}

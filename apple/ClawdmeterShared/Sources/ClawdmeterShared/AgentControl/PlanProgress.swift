import Foundation

/// Daemon-computed progress against an approved plan. Ships on
/// `AgentSession` so both Mac and iOS sidebar rows can render a thin
/// "completed / total" bar without per-device caching.
///
/// `nil` on a session means either (a) no approved plan yet, (b) the
/// approved plan has no extractable step markers (free-form prose), or
/// (c) the daemon hasn't run its first computation since approval.
/// Sidebar consumers treat all three the same — no bar.
public struct PlanProgress: Codable, Hashable, Sendable {
    /// Number of plan steps the daemon currently counts as complete.
    public let completed: Int
    /// Total plan steps extracted from the approved plan text. Capped
    /// at the same 24-step ceiling the staging parser uses so the bar
    /// stays readable for ultra-long plans.
    public let total: Int
    /// Wall-clock of the most recent recompute. Lets clients judge
    /// staleness independently of `AgentSession.lastEventAt`.
    public let lastComputedAt: Date

    public init(completed: Int, total: Int, lastComputedAt: Date) {
        self.completed = completed
        self.total = total
        self.lastComputedAt = lastComputedAt
    }

    /// 0...1 fraction for `ProgressView`. Guards against divide-by-zero
    /// (which only matters during the brief window between approval
    /// and the first computation — `total == 0` shouldn't normally
    /// reach a `PlanProgress` value, see `from(steps:now:)`).
    public var fraction: Double {
        guard total > 0 else { return 0 }
        return Double(completed) / Double(total)
    }

    /// Build a `PlanProgress` snapshot from a `[PlanStep]` array.
    /// Returns `nil` when `steps` is empty — callers treat that as
    /// "no progress data" and hide the bar entirely (the alternative,
    /// a 0/0 bar, would render as a static empty rectangle and confuse
    /// users into thinking the agent is stuck).
    public static func from(steps: [PlanStep], now: Date = Date()) -> PlanProgress? {
        guard !steps.isEmpty else { return nil }
        let completed = steps.reduce(0) { $0 + ($1.isComplete ? 1 : 0) }
        return PlanProgress(completed: completed, total: steps.count, lastComputedAt: now)
    }
}

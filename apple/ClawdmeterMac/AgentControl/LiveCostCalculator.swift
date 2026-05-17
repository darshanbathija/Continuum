import Foundation
import ClawdmeterShared
import OSLog

private let costLogger = Logger(subsystem: "com.clawdmeter.mac", category: "LiveCostCalculator")

/// Pre-flight cost estimate for the new-session sheet (D3 / Phase 8).
///
/// Reads per-repo historical `TokenTotals` from `UsageHistorySnapshot`,
/// derives an average per-session token count, scales by an effort
/// multiplier, and prices it through `Pricing.shared`.
///
/// The estimate is best-effort: when the repo has no history (new
/// project, freshly-cloned, "Other" bucket), `estimate` returns nil so
/// the UI can show "no estimate yet" instead of a misleading $0.
@MainActor
public final class LiveCostCalculator {
    public static let shared = LiveCostCalculator()

    /// Effort → token-volume multiplier. Anchored at `.medium = 1.0`.
    /// Minimal / low / high / xhigh scale around it. Numbers picked to
    /// roughly match observed Codex `reasoning_effort` token bursts:
    /// high pulls ~2× the reasoning tokens of medium, xhigh ~3×.
    public static func effortMultiplier(_ effort: ReasoningEffort?) -> Double {
        switch effort {
        case .minimal: return 0.4
        case .low: return 0.7
        case .medium, nil: return 1.0
        case .high: return 1.8
        case .xhigh: return 3.0
        case .max: return 4.0
        }
    }

    /// Goal text adds prompt tokens. Rough 1 token per 4 characters
    /// (English-ish). The agent's own thinking + tool I/O dominate the
    /// average session, so this is a small additive term.
    public static func goalTokenEstimate(_ goalLength: Int) -> Int {
        max(0, goalLength / 4)
    }

    /// Best-effort estimate. Returns nil when there is no history for
    /// this repo in the past-7-day window — the UI shows "no estimate
    /// yet" rather than a misleading zero.
    public func estimate(
        snapshot: UsageHistorySnapshot,
        repoKey: String,
        agent: AgentKind,
        model: String,
        effort: ReasoningEffort?,
        goalLength: Int
    ) -> Double? {
        let provider: UsageRecord.Provider = (agent == .claude) ? .claude : .codex
        let totals = snapshot.totals(for: provider)
        let window = totals.past7d

        // Find this repo's slice in the past-7d byRepo rollup. Match on
        // RepoKey normalization to handle worktree paths vs canonical
        // repo paths.
        let target = RepoIdentity.normalize(repoKey)
        let repoTotals = window.byRepo.first(where: { $0.repo == target })?.totals
        guard let repoTotals, repoTotals.totalTokens > 0 else { return nil }

        // Approximate session count. The snapshot doesn't carry per-repo
        // session counts directly; derive from byDay entries in the past
        // 7 days that have non-zero tokens. byDay lives on
        // ProviderTotals (not WindowTotals) and spans the full 30-day
        // chart window, so filter to the past 7 days first. One day ≠
        // one session, so this over-counts the divisor and the result
        // skews conservative — under-estimating per-session usage is
        // the right way to err here.
        let sevenDaysAgo = Calendar.current.date(
            byAdding: .day, value: -7, to: Date()
        ) ?? Date.distantPast
        let activeDays = max(1, totals.byDay.filter { (day, t) in
            day >= sevenDaysAgo && t.totalTokens > 0
        }.count)
        let avgPerSession = TokenTotals(
            inputTokens: repoTotals.inputTokens / activeDays,
            outputTokens: repoTotals.outputTokens / activeDays
        )

        // Scale by effort + add goal tokens. Goal tokens count as input.
        let multiplier = Self.effortMultiplier(effort)
        let goalTokens = Self.goalTokenEstimate(goalLength)
        let scaled = TokenTotals(
            inputTokens: Int(Double(avgPerSession.inputTokens) * multiplier) + goalTokens,
            outputTokens: Int(Double(avgPerSession.outputTokens) * multiplier)
        )

        let cost = Pricing.shared.cost(for: model, tokens: scaled)
        // Convert Decimal → Double for wire. We accept the imprecision
        // here: the value is a hint, not an invoice.
        let dollars = NSDecimalNumber(decimal: cost).doubleValue
        guard dollars > 0 else { return nil }
        costLogger.debug(
            "Preflight cost: repo=\(target, privacy: .public) model=\(model, privacy: .public) effort=\(effort?.rawValue ?? "default", privacy: .public) avg_in=\(avgPerSession.inputTokens) avg_out=\(avgPerSession.outputTokens) → $\(dollars)"
        )
        return dollars
    }
}

/// Rate-limit cap projection. Sessions v2 Phase 8.
///
/// Reads the live `UsageData.weeklyPct` from the running poller, projects
/// the additional consumption this session would add (estimated tokens
/// ÷ provider-specific weekly cap), and reports the union.
@MainActor
public final class RateLimitChecker {
    public static let shared = RateLimitChecker()

    /// Approximate weekly token budget on a Max-tier Anthropic plan
    /// (the user's current plan per CLAUDE.md). 5M tokens lines up with
    /// historical observations of "1% per ~50k tokens." Codex doesn't
    /// publish a comparable cap; we reuse the same number as a rough
    /// upper bound (errs toward over-projecting cap consumption).
    public static let weeklyTokenBudget: Int = 5_000_000

    public func projectedWeeklyCap(
        currentWeeklyPct: Int,
        estimatedTokens: Int
    ) -> Double {
        let baseline = Double(currentWeeklyPct) / 100.0
        let added = Double(estimatedTokens) / Double(Self.weeklyTokenBudget)
        return min(1.0, baseline + added)
    }

    /// Suggested swap rule: Opus is the costliest; recommend Sonnet.
    /// Sonnet → Haiku for ultra-budget. Returns nil for already-cheap
    /// models or non-Anthropic models (where the swap surface differs).
    public func suggestedSwap(currentModel: String) -> String? {
        switch currentModel {
        case let m where m.contains("opus"):
            return "claude-sonnet-4-6"
        case let m where m.contains("sonnet"):
            return "claude-haiku-4-5-20251001"
        default:
            return nil
        }
    }
}

import Foundation

/// Daemon-side completion heuristic for approved plans. Purpose-built
/// for the sidebar "progress vs approved plan" bar — does NOT reuse
/// `StagingParser.computePlanStepsIncremental`, whose
/// `inPlan = lcPlan.contains(needle)` check trivially fires for every
/// plan-derived step (the step IS a substring of the plan it came
/// from) and would jump the bar to N/N on approval.
///
/// The fix is twofold:
///   1. Only match step needles against post-approval messages, never
///      against the plan text itself.
///   2. Apply a self-match guard so the assistant message that emitted
///      the plan doesn't auto-complete every step it referenced.
///
/// `compute(...)` returns `nil` when the plan has no extractable steps
/// (prose-only plans). Sidebar consumers treat `nil` as "no bar."
public enum PlanProgressComputer {
    /// First-N-char window used to match a step against later message
    /// bodies. 30 mirrors the window the existing staging parser uses
    /// (`SessionChatStore.swift` `computePlanStepsIncremental`) so the
    /// bar's notion of "complete" stays predictable for users who also
    /// look at `PlanTrackerPane`.
    static let needlePrefix: Int = 30

    /// Step ceiling — matches `StagingParser`'s cap. Plans with more
    /// than 24 markers truncate at 24 so the bar stays legible.
    static let stepCap: Int = 24

    public static func compute(
        approvedPlanText: String,
        messagesSinceApproval: [ChatMessage],
        approvedAt: Date,
        now: Date = Date()
    ) -> PlanProgress? {
        let stepTexts = TahoePlanParser.steps(from: approvedPlanText, cap: stepCap)
        guard !stepTexts.isEmpty else { return nil }

        // Pre-lowercase every candidate body exactly once. The post-
        // approval timestamp filter is what prevents the plan-emission
        // assistant message (which contains every step's text by
        // definition) from self-completing the whole plan — that
        // message's `at` is at-or-before `approvedAt`.
        let candidateBodies: [String] = messagesSinceApproval
            .filter { $0.at > approvedAt }
            .filter { msg in
                switch msg.kind {
                case .assistantText, .toolCall, .toolResult: return true
                case .userText, .meta: return false
                }
            }
            .flatMap { msg -> [String] in
                var bodies: [String] = [msg.body.lowercased()]
                if let detail = msg.detail, !detail.isEmpty {
                    bodies.append(detail.lowercased())
                }
                return bodies
            }

        let steps: [PlanStep] = stepTexts.enumerated().map { idx, text in
            let lowered = text.lowercased()
            let needle = String(lowered.prefix(needlePrefix))
            let needleLen = needle.count

            // Self-match guard: a candidate body that's basically just
            // the step text repeated back (the agent quoting the step
            // verbatim while saying "next: step X") shouldn't count
            // as completion. Same shape as the existing guard in
            // SessionChatStore's `computePlanStepsIncremental`.
            let isComplete = candidateBodies.contains { body in
                guard body.contains(needle) else { return false }
                if body.hasPrefix(needle) && body.count <= needleLen + 4 {
                    return false
                }
                return true
            }
            return PlanStep(id: "plan-progress-\(idx)", text: text, isComplete: isComplete)
        }

        return PlanProgress.from(steps: steps, now: now)
    }
}

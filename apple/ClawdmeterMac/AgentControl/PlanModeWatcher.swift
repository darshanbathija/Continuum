import Foundation
import ClawdmeterShared
import OSLog

private let planWatcherLogger = Logger(subsystem: "com.clawdmeter.mac", category: "PlanModeWatcher")

/// Watches a Claude session's JSONL for the `ExitPlanMode` tool call.
/// When it fires, the daemon flips the session's status to `.planning`
/// with `planText` populated, and emits a `planReady` event so the UI
/// shows the yellow pill + the structured plan card.
///
/// Per D13: when the user approves, the daemon suspends the plan-mode runtime
/// and spawns a fresh `claude --resume <id> --permission-mode acceptEdits`.
/// The overlay covers the visual swap.
public final class PlanModeWatcher: @unchecked Sendable {

    public typealias PlanReadyHandler = @Sendable (_ sessionId: UUID, _ planText: String, _ files: [PlanCardView.PlanFile]) -> Void

    public let sessionId: UUID
    public let handler: PlanReadyHandler

    private var alreadyFired = false

    public init(sessionId: UUID, handler: @escaping PlanReadyHandler) {
        self.sessionId = sessionId
        self.handler = handler
    }

    /// Feed one JSONL event. If it's an `ExitPlanMode` tool_use, parse
    /// the plan text and fire the handler.
    public func feed(_ event: [String: Any]) {
        guard !alreadyFired else { return }
        guard event["type"] as? String == "assistant",
              let message = event["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]]
        else { return }
        for block in content {
            if block["type"] as? String == "tool_use",
               block["name"] as? String == "ExitPlanMode",
               let input = block["input"] as? [String: Any],
               let plan = input["plan"] as? String {
                alreadyFired = true
                let files = Self.parseFiles(from: plan)
                planWatcherLogger.info("PlanModeWatcher fired for session \(self.sessionId.uuidString, privacy: .public) — plan length=\(plan.count, privacy: .public)")
                handler(sessionId, plan, files)
                return
            }
        }
    }

    // MARK: - Plan text → file list

    /// Best-effort parse of a plan summary for file references. Claude's
    /// plan text is natural language; we look for `path/to/file.ext` patterns
    /// and synthesize empty file diffs (the real diff comes when the agent
    /// actually edits the files post-approval — we only show "files I plan
    /// to touch" in the card).
    static func parseFiles(from plan: String) -> [PlanCardView.PlanFile] {
        // Match common file path patterns with at least one slash + an
        // extension. Crude but correct for most cases.
        let pattern = #"([A-Za-z0-9_.\-]+/)+[A-Za-z0-9_.\-]+\.[a-zA-Z0-9]{1,8}"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let range = NSRange(plan.startIndex..<plan.endIndex, in: plan)
        let matches = regex.matches(in: plan, options: [], range: range)
        var seen = Set<String>()
        var out: [PlanCardView.PlanFile] = []
        for match in matches {
            if let r = Range(match.range, in: plan) {
                let path = String(plan[r])
                if seen.insert(path).inserted {
                    out.append(PlanCardView.PlanFile(
                        filename: path,
                        addedLines: 0,
                        removedLines: 0,
                        diff: "(diff appears after approval)"
                    ))
                }
            }
        }
        return out
    }
}

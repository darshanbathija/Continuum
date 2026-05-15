import Foundation
import ClawdmeterShared
import OSLog

private let doneLogger = Logger(subsystem: "com.clawdmeter.mac", category: "DoneDetector")

/// Heuristic detector for "agent finished its goal" (D4).
///
/// Three signals, all gated on an **end-of-turn boundary** (last event is
/// an assistant text message and no `tool_use` is pending a `tool_result`):
///
/// - **(a) High-confidence text** — final assistant message contains the
///   user-supplied goal text (lowercased substring + punctuation-trim)
///   **AND** contains a completion verb from
///   `{done, finished, complete, shipped, passes, passing}`.
/// - **(b) Side-effect** — earlier in this same turn, a `Bash` tool ran
///   `git commit` and exit code was 0.
/// - **(c) Tiebreaker** — final assistant message contains the goal text
///   (no completion verb required) **AND** ≥ 10 minutes have elapsed
///   since the previous end-of-turn boundary (true idle — Codex Round 2
///   reviewer concern: prevent slow back-and-forth false-positives).
///
/// The detector is stateful: it watches a stream of JSONL events from one
/// session and emits at most one `.done` per session lifetime.
public final class DoneDetector: @unchecked Sendable {

    public typealias DoneHandler = @Sendable (_ sessionId: UUID, _ trigger: String) -> Void

    public let sessionId: UUID
    public let goal: String?
    public let handler: DoneHandler

    /// Lower-cased goal text with non-alphanumeric stripped, for matching.
    private let normalizedGoal: String?

    /// Tracks the latest end-of-turn boundary time. Signal (c) compares
    /// the next-turn time to this.
    private var lastBoundaryAt: Date?

    /// True once we've fired `.done` for this session. We never re-fire.
    private var alreadyFired = false

    /// True while a tool_use is awaiting its tool_result. End-of-turn
    /// boundary requires this to be false.
    private var hasPendingToolCall = false

    /// Within the current turn, has a `git commit` Bash call succeeded?
    private var hasCommitInTurn = false

    /// Snapshot of the last assistant text message body (for signals a, c).
    private var lastAssistantText = ""

    /// Completion verbs that trigger signal (a) when combined with goal text.
    private static let completionVerbs: [String] = [
        "done", "finished", "complete", "shipped", "passes", "passing", "ready",
    ]

    /// Tiebreaker idle threshold for signal (c).
    public static let idleThreshold: TimeInterval = 600  // 10 minutes

    public init(sessionId: UUID, goal: String?, handler: @escaping DoneHandler) {
        self.sessionId = sessionId
        self.goal = goal
        self.normalizedGoal = goal.map(DoneDetector.normalize)
        self.handler = handler
    }

    /// Feed one parsed JSONL event into the detector. Returns the trigger
    /// string if `.done` fires this call, or nil.
    @discardableResult
    public func feed(_ event: [String: Any], at: Date = Date()) -> String? {
        guard !alreadyFired else { return nil }

        let type = event["type"] as? String

        // Track tool_use → tool_result pairing for the boundary check.
        if type == "assistant" {
            let content = extractAssistantContent(event)
            // Look for tool_use blocks.
            let toolUses = content.compactMap { $0["type"] as? String == "tool_use" ? $0 : nil }
            let hasNewToolUse = !toolUses.isEmpty
            if hasNewToolUse {
                hasPendingToolCall = true
            }
            // Capture the assistant's text body (concatenate all text blocks).
            let textBlocks = content.compactMap { block -> String? in
                guard block["type"] as? String == "text" else { return nil }
                return block["text"] as? String
            }
            if !textBlocks.isEmpty {
                lastAssistantText = textBlocks.joined(separator: "\n")
            }
        }

        if type == "tool_result" || type == "tool_use_result" {
            // A tool just returned — clear the pending flag. Also check for
            // `git commit` exit 0 as signal (b) within the same turn.
            hasPendingToolCall = false
            if isSuccessfulGitCommit(event) {
                hasCommitInTurn = true
                doneLogger.debug("DoneDetector: observed successful git commit in current turn")
            }
        }

        // End-of-turn boundary check: last event was assistant text with
        // no remaining pending tool use.
        if type == "assistant" && !hasPendingToolCall {
            let now = at
            let timeSinceLastBoundary = lastBoundaryAt.map { now.timeIntervalSince($0) } ?? .infinity

            // Signal (a): high-confidence text
            if matchesSignalA() {
                fire(trigger: "signal-a:goal+verb"); return "signal-a:goal+verb"
            }
            // Signal (b): git commit success this turn
            if hasCommitInTurn {
                fire(trigger: "signal-b:git-commit"); return "signal-b:git-commit"
            }
            // Signal (c): goal text + ≥10min idle since previous boundary
            if matchesSignalC() && timeSinceLastBoundary >= Self.idleThreshold {
                fire(trigger: "signal-c:goal+idle"); return "signal-c:goal+idle"
            }

            lastBoundaryAt = now
            hasCommitInTurn = false  // reset for next turn
        }
        return nil
    }

    // MARK: - Signal evaluators

    private func matchesSignalA() -> Bool {
        guard let normalizedGoal else { return false }
        let normalized = Self.normalize(lastAssistantText)
        guard normalized.contains(normalizedGoal) else { return false }
        return Self.completionVerbs.contains { normalized.contains($0) }
    }

    private func matchesSignalC() -> Bool {
        guard let normalizedGoal else { return false }
        return Self.normalize(lastAssistantText).contains(normalizedGoal)
    }

    /// Returns true if the event represents a Bash tool result whose
    /// command was a `git commit` and whose exit code was 0.
    ///
    /// Claude's tool_result schema embeds `tool_use_id`, `content` (string
    /// or list of blocks), and sometimes `is_error`. We look for the
    /// presence of `git commit` in the content + absence of an error flag.
    private func isSuccessfulGitCommit(_ event: [String: Any]) -> Bool {
        if let isError = event["is_error"] as? Bool, isError { return false }
        // Content may be string or array of blocks.
        if let s = event["content"] as? String {
            return s.contains("git commit") || s.contains("[main") || s.contains("master ")
        }
        if let blocks = event["content"] as? [[String: Any]] {
            for block in blocks {
                if let text = block["text"] as? String,
                   text.contains("git commit") || text.contains("[main") || text.contains("master ") {
                    return true
                }
            }
        }
        return false
    }

    private func extractAssistantContent(_ event: [String: Any]) -> [[String: Any]] {
        guard let message = event["message"] as? [String: Any] else { return [] }
        if let content = message["content"] as? [[String: Any]] { return content }
        // Some streams encode `content` as a flat string for simple text messages.
        if let s = message["content"] as? String {
            return [["type": "text", "text": s]]
        }
        return []
    }

    private func fire(trigger: String) {
        alreadyFired = true
        doneLogger.info("DoneDetector fired for session \(self.sessionId.uuidString, privacy: .public) — trigger=\(trigger, privacy: .public)")
        handler(sessionId, trigger)
    }

    // MARK: - Normalization

    static func normalize(_ s: String) -> String {
        s.lowercased().unicodeScalars.map { scalar -> String in
            // Keep [a-z0-9 ]; collapse other punctuation to spaces.
            if scalar.value >= 0x30 && scalar.value <= 0x39 { return String(scalar) }
            if scalar.value >= 0x61 && scalar.value <= 0x7A { return String(scalar) }
            return " "
        }.joined()
    }
}

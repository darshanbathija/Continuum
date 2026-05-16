import Foundation

/// File-level parser for Codex JSONL rollouts.
///
/// Per plan A12 + verified semantics: Codex emits `event_msg` events with
/// `payload.type == "token_count"`, each carrying a CUMULATIVE
/// `payload.info.total_token_usage` snapshot. We compute per-turn deltas by
/// subtracting the previous cumulative.
///
/// Token shape:
///   - `input_tokens` includes both fresh + cached prompt; `cached_input_tokens`
///     is a subset of that. We map cached portion → `cacheReadTokens`,
///     remainder → `inputTokens`.
///   - `output_tokens` already includes `reasoning_output_tokens`, so we map
///     all output to `outputTokens` and leave `reasoningTokens` at 0 to avoid
///     double-counting in `totalTokens`.
///   - `cache_creation_input_tokens` doesn't exist for Codex.
///
/// Repo + model come from `session_meta.payload.cwd` and
/// `turn_context.payload.model` events near the top of each rollout. We
/// observed exactly one of each per file in real on-disk data, but we still
/// update them on any further occurrences so out-of-the-ordinary multi-turn
/// rollouts attribute correctly.
///
/// Non-monotonic cumulative drops (session reset mid-file) → the new value
/// is treated as a fresh baseline rather than emitted as a negative delta.
public enum CodexUsageParser {

    public static func parse(file url: URL) throws -> [UsageRecord] {
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return [] }

        var records: [UsageRecord] = []
        var currentCwd: RepoKey? = nil
        var currentModel: String = "gpt-5"
        var previousCumulative: TokenTotals = .zero

        // Split on newlines. JSONL line endings are \n; tolerate \r\n.
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        for rawLine in lines {
            let lineData = Data(rawLine)
            guard let root = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            let type = root["type"] as? String ?? ""
            let payload = root["payload"] as? [String: Any] ?? [:]

            switch type {
            case "session_meta":
                if let cwd = payload["cwd"] as? String, !cwd.isEmpty {
                    currentCwd = RepoIdentity.normalize(cwd)
                }

            case "turn_context":
                if let model = payload["model"] as? String, !model.isEmpty {
                    currentModel = model
                }
                if let cwd = payload["cwd"] as? String, !cwd.isEmpty {
                    currentCwd = RepoIdentity.normalize(cwd)
                }

            case "event_msg":
                guard (payload["type"] as? String) == "token_count",
                      let info = payload["info"] as? [String: Any],
                      let totalUsage = info["total_token_usage"] as? [String: Any]
                else { continue }

                let inputTotal = intValue(totalUsage["input_tokens"])
                let cachedInput = intValue(totalUsage["cached_input_tokens"])
                let output = intValue(totalUsage["output_tokens"])

                // Build the cumulative-as-of-this-event TokenTotals. Cost is
                // computed at delta-time, not here.
                let cumulative = TokenTotals(
                    inputTokens: max(0, inputTotal - cachedInput),
                    outputTokens: output,
                    cacheCreationTokens: 0,
                    cacheReadTokens: cachedInput,
                    reasoningTokens: 0,
                    costUSD: 0
                )

                let delta: TokenTotals
                if cumulative.totalTokens < previousCumulative.totalTokens
                    || cumulative.inputTokens < previousCumulative.inputTokens
                    || cumulative.outputTokens < previousCumulative.outputTokens
                    || cumulative.cacheReadTokens < previousCumulative.cacheReadTokens {
                    // Non-monotonic — session reset within this file. Codex
                    // can reset individual counters while total_tokens still
                    // increases, so check every cumulative field, not just
                    // the aggregate total.
                    delta = cumulative
                } else {
                    delta = TokenTotals(
                        inputTokens: max(0, cumulative.inputTokens - previousCumulative.inputTokens),
                        outputTokens: max(0, cumulative.outputTokens - previousCumulative.outputTokens),
                        cacheCreationTokens: 0,
                        cacheReadTokens: max(0, cumulative.cacheReadTokens - previousCumulative.cacheReadTokens),
                        reasoningTokens: 0,
                        costUSD: 0
                    )
                }

                previousCumulative = cumulative

                // Skip zero-delta events (heartbeat / no-op snapshots).
                if delta.totalTokens == 0 { continue }

                let timestamp = Self.parseTimestamp(root["timestamp"])

                records.append(UsageRecord(
                    provider: .codex,
                    timestamp: timestamp,
                    model: currentModel,
                    tokens: delta,
                    repo: currentCwd,
                    dedupKey: nil
                ))

            default:
                continue
            }
        }

        return records
    }

    // MARK: - Helpers

    private static func intValue(_ raw: Any?) -> Int {
        if let n = raw as? Int { return n }
        if let d = raw as? Double { return Int(d) }
        if let s = raw as? String, let n = Int(s) { return n }
        return 0
    }

    private static func parseTimestamp(_ raw: Any?) -> Date {
        guard let s = raw as? String else { return Date() }
        if let d = isoFractional.date(from: s) { return d }
        if let d = isoFormatter.date(from: s) { return d }
        return Date()
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

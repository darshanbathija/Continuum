import Foundation

/// Stateless line parser for Claude Code JSONL session logs.
///
/// Per plan A12: `repo` comes from the per-line `cwd` field — a single JSONL
/// can hold multiple cwds (verified against real on-disk data). No
/// per-file-fallback to the directory slug because Claude's slug encoding
/// (`-` for both `/` and ` `) is not reversible.
///
/// `nonisolated` static so the `UsageHistoryLoader` actor's `TaskGroup` can
/// call this in parallel without re-entering the actor.
public enum ClaudeUsageParser {

    /// Parse one JSONL line. Returns `nil` for lines that don't carry a usage
    /// payload (system messages, tool outputs, partial mid-write lines).
    /// Throws only for catastrophic decoding failures the caller wants to
    /// log; lines without `message.usage` are NOT errors.
    public static func parse(line: Data) -> UsageRecord? {
        guard let root = try? JSONSerialization.jsonObject(with: line, options: []) as? [String: Any],
              let messageRaw = root["message"] as? [String: Any],
              let usageRaw = messageRaw["usage"] as? [String: Any]
        else { return nil }

        // Pull token counts. Missing fields are OK — Claude's older logs
        // didn't carry cache fields, treat absent as zero.
        let tokens = TokenTotals(
            inputTokens: intValue(usageRaw["input_tokens"]),
            outputTokens: intValue(usageRaw["output_tokens"]),
            cacheCreationTokens: intValue(usageRaw["cache_creation_input_tokens"]),
            cacheReadTokens: intValue(usageRaw["cache_read_input_tokens"]),
            reasoningTokens: 0,
            costUSD: 0
        )

        // Total tokens have to be > 0 for the line to be "usage-bearing" —
        // an assistant message with all-zero usage is the empty-completion
        // edge case that ccusage also drops.
        if tokens.totalTokens == 0 { return nil }

        // Model name. Newer logs put it on the message; older logs sometimes
        // omit it. Default to a sentinel that Pricing.swift will resolve via
        // prefix-match (or fall through to unpriced).
        let model = (messageRaw["model"] as? String) ?? "unknown"

        // Timestamp — Claude logs ISO 8601 at the top level.
        let timestamp: Date = {
            // Lock-free fast path first — ICU formatters contend under the
            // loader's concurrent file parse (v0.31.17 energy bug).
            if let raw = root["timestamp"] as? String {
                if let parsed = ISO8601Fast.parse(raw) {
                    return parsed
                }
                if let parsed = Self.isoFormatter.date(from: raw) {
                    return parsed
                }
                if let parsed = Self.isoFractional.date(from: raw) {
                    return parsed
                }
            }
            return Date()
        }()

        // Repo. Top-level cwd. nil means "(unknown)" downstream.
        let repo: RepoKey? = {
            if let cwd = root["cwd"] as? String, !cwd.isEmpty {
                return RepoIdentity.normalize(cwd)
            }
            return nil
        }()

        // Dedup key. ccusage collapses identical events on
        // `message.id` + top-level `requestId`. Claude Code's opus-4-8-era
        // JSONL DROPPED `requestId` (only `message.id` remains). Requiring
        // both here returned nil for the new format → every row was treated as
        // unique → no cross-file dedup → replayed/resumed session history was
        // counted 2-3x (a ~2.4x over-count vs ccusage, e.g. today's Claude
        // showed ~$1528 vs ccusage's ~$625). ccusage still collapses these by
        // message.id (its `${id}:${requestId}` key folds an absent requestId to
        // a constant), so require only `message.id` and treat a missing
        // `requestId` as an empty qualifier — same dedup outcome as ccusage.
        let dedupKey: String? = {
            guard let messageID = messageRaw["id"] as? String else { return nil }
            let requestID = root["requestId"] as? String
            return "\(messageID):\(requestID ?? "")"
        }()

        return UsageRecord(
            provider: .claude,
            timestamp: timestamp,
            model: model,
            tokens: tokens,
            repo: repo,
            dedupKey: dedupKey
        )
    }

    // MARK: - Helpers

    private static func intValue(_ raw: Any?) -> Int {
        if let n = raw as? Int { return n }
        if let d = raw as? Double { return Int(d) }
        if let s = raw as? String, let n = Int(s) { return n }
        return 0
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

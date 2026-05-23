// Token-aware analytics parser for Antigravity 2's `~/.gemini/antigravity/`
// layout. Replaces v0.5.11's `GeminiUsageParser` which walked the
// `~/.gemini/tmp/<repo>/logs.json` files that Gemini CLI v0.42 wrote —
// Antigravity 2 stopped writing those.
//
// Source data (Disk mode):
//   - `~/.gemini/antigravity/conversations/<uuid>.pb`  per-conversation file
//   - `~/.gemini/antigravity/brain/<uuid>/`            per-conversation brain dir
//   - `~/.gemini/antigravity/agyhub_summaries_proto.pb` UUID→cwd index
//   - `~/.gemini/antigravity/antigravity_state.pbtxt`  current model
//
// Per Commit 4's deviation note: per-conversation `.pb` files are
// encrypted at rest. We can't extract exact token counts from them
// without the SDK's decryption key (provided by the running language
// server). Disk mode therefore emits a coarse estimate via
// `ConversationProtoParser.probe`:
//   - `requestCount` = number of metadata.json files in the brain
//     (one per artifact ≈ one model turn)
//   - estimated token count = sum of plaintext .md byte sizes ÷ 4
//
// The analytics UI surfaces this with a `~` provisional marker. SDK
// mode (Commit 10) replaces these with real `agent.conversation.total_usage`
// readings via the Python sidecar.

import Foundation

/// Parser for Antigravity 2's per-conversation usage data. `nonisolated`
/// static so `UsageHistoryLoader`'s TaskGroup can call it in parallel
/// without re-entering the actor.
public enum AntigravityUsageParser {

    /// Parses one conversation `.pb` file plus the matching brain dir.
    /// Returns a single `UsageRecord` per conversation when there's at
    /// least one turn — turn count is derived from the brain dir's
    /// `*.metadata.json` count. Returns an empty array when the brain dir
    /// has no turns yet.
    ///
    /// - Parameters:
    ///   - conversationURL: `<dataDir>/conversations/<uuid>.{pb,db}`. The
    ///     file extension is irrelevant — the parser only uses file size
    ///     + mtime from this URL; token volume comes from the brain dir.
    ///     Accepting both extensions is what lets one parser cover the
    ///     legacy protobuf format and the SQLite-WAL format Antigravity
    ///     migrated to mid-2026.
    ///   - antigravityDataDir: e.g. `~/.gemini/antigravity/` for the
    ///     desktop IDE or `~/.gemini/antigravity-cli/` for the `agy` CLI.
    ///     The parser locates `brain/<uuid>/` under this root.
    ///   - brainIndex: pre-built UUID→cwd lookup from
    ///     `BrainSummaryIndexer.read(at:)` for repo-bucketing.
    ///   - modelName: current model name (e.g. `"gemini-3.5-flash"`).
    ///     Used to drive pricing lookup.
    ///   - dedupPrefix: namespace for the dedup key so the desktop and
    ///     agy surfaces don't collide if a UUID ever appears in both.
    ///     Defaults to `"antigravity"` (desktop IDE); agy callers pass
    ///     `"agy"`.
    public static func parse(
        conversationURL: URL,
        antigravityDataDir: URL,
        brainIndex: BrainSummaryIndex,
        modelName: String,
        dedupPrefix: String = "antigravity"
    ) throws -> [UsageRecord] {
        // Brain UUID == conversation file basename without extension.
        let brainUUID = conversationURL.deletingPathExtension().lastPathComponent
        let brainURL = antigravityDataDir
            .appendingPathComponent("brain", isDirectory: true)
            .appendingPathComponent(brainUUID, isDirectory: true)

        let probe = ConversationProtoParser.probe(
            conversationURL: conversationURL,
            brainURL: brainURL
        )
        // No turns yet → no record (fresh sessions or stale empty brains).
        guard probe.turnCount > 0 else { return [] }

        let repo = repoKey(forBrainUUID: brainUUID, in: brainIndex)
        let timestamp = probe.lastModified

        // v0.23.9: .db files (the SQLite WAL format Antigravity 2.0.6+
        // writes for current sessions) have plaintext step_payload
        // blobs containing real UsageMetadata sub-messages. Try the
        // precise extractor first; fall back to the byte estimator
        // when zero matches are found (signature changed, .pb file
        // that's still encrypted, etc.). See
        // AntigravityDBUsageParser for the reverse-engineered field
        // mapping.
        let tokens: TokenTotals
        if conversationURL.pathExtension == "db" {
            let dbUsage = AntigravityDBUsageParser.parseUsage(dbURL: conversationURL)
            if dbUsage.recordCount > 0 {
                tokens = TokenTotals(
                    inputTokens: dbUsage.inputTokens,
                    outputTokens: dbUsage.outputTokens,
                    cacheCreationTokens: 0,
                    cacheReadTokens: dbUsage.cachedTokens,
                    reasoningTokens: dbUsage.reasoningTokens,
                    costUSD: 0,
                    requestCount: dbUsage.recordCount
                )
            } else {
                // .db file but no UsageMetadata extracted — fall
                // through to the byte estimator below.
                tokens = byteEstimateTokens(probe: probe)
            }
        } else {
            tokens = byteEstimateTokens(probe: probe)
        }

        return [UsageRecord(
            provider: .gemini,
            timestamp: timestamp,
            model: modelName,
            tokens: tokens,
            repo: repo,
            // Stable dedup key: brain UUID never changes for the lifetime
            // of the conversation, so re-parsing the same file across
            // cache invalidations doesn't double-count.
            dedupKey: "\(dedupPrefix):\(brainUUID)"
        )]
    }

    /// Coarse fallback: bytes-per-turn × ¼ ≈ tokens, split 70/30 input
    /// vs output. Used for .pb files (still encrypted) and for .db
    /// files where the proto signature didn't match.
    private static func byteEstimateTokens(probe: ConversationProbe) -> TokenTotals {
        let totalEst = probe.estimatedTokens
        let promptEst = (totalEst * 70) / 100
        let outputEst = totalEst - promptEst
        return TokenTotals(
            inputTokens: promptEst,
            outputTokens: outputEst,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            reasoningTokens: 0,
            costUSD: 0,
            requestCount: probe.turnCount
        )
    }

    /// Resolves the repo string for a brain UUID. Tries the index first
    /// (fast path); falls back to the literal UUID prefix when the index
    /// doesn't have a matching entry (fresh session before the index has
    /// been rebuilt).
    private static func repoKey(forBrainUUID uuid: String, in index: BrainSummaryIndex) -> String {
        if let summary = index.byUUID[uuid] {
            if let cwd = summary.cwd { return cwd.path }
            if let title = summary.projectTitle { return title }
        }
        return "antigravity/\(uuid.prefix(8))"
    }
}

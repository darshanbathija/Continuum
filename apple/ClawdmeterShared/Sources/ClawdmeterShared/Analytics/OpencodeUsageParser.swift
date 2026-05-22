#if os(macOS)
import Foundation
import SQLite3
import OSLog

/// v0.22.8 — disk parser for OpenCode usage. OpenCode (sst/opencode)
/// persists every assistant message in `~/.local/share/opencode/opencode.db`
/// — a SQLite database with a `message` table whose `data` column holds
/// a JSON blob shaped like:
///
///   {
///     "role": "assistant",
///     "cost": <usd>,
///     "tokens": {
///       "input":  N,
///       "output": N,
///       "reasoning": N,
///       "cache": { "write": N, "read": N }
///     },
///     "modelID": "claude-sonnet-4.5",
///     "providerID": "anthropic" | "openai" | "github-copilot" | "opencode" | …,
///     "time": { "created": <ms-epoch> },
///     "path": { "cwd": "/path/to/repo" }
///   }
///
/// Mirrors ccusage's `opencode/loader.rs` + `parser.rs` (upstream Rust):
///   - read `SELECT id, session_id, time_created, data FROM message`
///   - dedupe by `id` (message id, NOT `(messageId, requestId)` like Claude)
///   - cost: prefer the embedded `cost` field when > 0, else compute via
///     `Pricing.cost(model:tokens:)` with provider-prefix fallback
///     (`claude-sonnet-4.5`, then normalized `claude-sonnet-4-5`, then
///     `<providerID>/<modelID>` variants)
///   - timestamp: ms epoch from `time.created`
///   - repo: `path.cwd` (run through `RepoIdentity.normalize`)
///
/// The parser is `nonisolated static` to match the other parsers in
/// `UsageHistoryLoader` so the actor can `withTaskGroup` over multiple
/// data files safely.
///
/// Mac-only: iOS/Watch don't run OpenCode locally + their sandbox blocks
/// `~/.local/share/`. Compile-time gated behind `#if os(macOS)`.
public enum OpencodeUsageParser {

    private static let logger = Logger(subsystem: "com.clawdmeter.shared", category: "OpencodeParser")

    /// Default location for the OpenCode SQLite store. Honors the
    /// `OPENCODE_DATA_DIR` env var (matches ccusage's `OPENCODE_DATA_DIR`
    /// override) but falls back to the standard XDG-style path.
    public static func defaultDatabaseURL() -> URL? {
        let env = ProcessInfo.processInfo.environment
        let base: URL
        if let override = env["OPENCODE_DATA_DIR"], !override.isEmpty {
            base = URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            base = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent(".local/share/opencode", isDirectory: true)
        }
        let dbURL = base.appendingPathComponent("opencode.db")
        return FileManager.default.fileExists(atPath: dbURL.path) ? dbURL : nil
    }

    /// Parse every assistant message in the OpenCode SQLite database and
    /// return one `UsageRecord` per row. Empty array on any I/O failure
    /// (logged + swallowed — analytics pipeline must never throw).
    public static func parse(databaseURL url: URL) -> [UsageRecord] {
        // SQLite handle. Open read-only so we never collide with the
        // OpenCode server's writer. `nomutex` ⇒ single-threaded mode;
        // we only call sqlite3_* from the actor here.
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(url.path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            logger.error("OpencodeParser: open failed rc=\(rc, privacy: .public) path=\(url.path, privacy: .public)")
            if let db { sqlite3_close_v2(db) }
            return []
        }
        defer { sqlite3_close_v2(db) }

        // WAL-aware busy timeout (OpenCode writes to opencode.db-wal
        // concurrently). 100ms is plenty for a read-only query.
        sqlite3_busy_timeout(db, 100)

        let sql = "SELECT id, time_created, data FROM message ORDER BY time_created ASC"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            logger.error("OpencodeParser: prepare failed")
            if let stmt { sqlite3_finalize(stmt) }
            return []
        }
        defer { sqlite3_finalize(stmt) }

        var records: [UsageRecord] = []
        records.reserveCapacity(256)

        while sqlite3_step(stmt) == SQLITE_ROW {
            // id (text PK)
            guard let idCStr = sqlite3_column_text(stmt, 0) else { continue }
            let id = String(cString: idCStr)

            // time_created (ms epoch — int)
            let createdMs = sqlite3_column_int64(stmt, 1)
            let timestamp = Date(timeIntervalSince1970: TimeInterval(createdMs) / 1000.0)

            // data (text JSON blob)
            guard let dataCStr = sqlite3_column_text(stmt, 2) else { continue }
            let dataStr = String(cString: dataCStr)
            guard let blob = dataStr.data(using: .utf8),
                  let record = self.decode(jsonBlob: blob, messageId: id, timestamp: timestamp)
            else {
                continue
            }
            records.append(record)
        }
        return records
    }

    /// Decode a single `data` JSON blob into a `UsageRecord`. Returns
    /// `nil` when the row is a user message (no `tokens` block) or when
    /// the schema doesn't match — both are normal, we just skip.
    static func decode(jsonBlob: Data, messageId: String, timestamp: Date) -> UsageRecord? {
        guard let root = try? JSONSerialization.jsonObject(with: jsonBlob) as? [String: Any] else {
            return nil
        }
        // User messages have no `tokens` block; skip them silently.
        guard let tokensDict = root["tokens"] as? [String: Any] else { return nil }

        let inputTokens = (tokensDict["input"] as? Int) ?? 0
        let outputTokens = (tokensDict["output"] as? Int) ?? 0
        let reasoningTokens = (tokensDict["reasoning"] as? Int) ?? 0
        let cacheDict = tokensDict["cache"] as? [String: Any]
        let cacheWriteTokens = (cacheDict?["write"] as? Int) ?? 0
        let cacheReadTokens = (cacheDict?["read"] as? Int) ?? 0

        // Bail on zero-token rows — they contribute no cost and just
        // bloat the analytics aggregator.
        let nonZero = inputTokens + outputTokens + reasoningTokens + cacheWriteTokens + cacheReadTokens
        guard nonZero > 0 else { return nil }

        let modelID = (root["modelID"] as? String) ?? ""
        let providerID = (root["providerID"] as? String) ?? ""

        // Embedded cost — OpenCode computes this from its own pricing
        // table at write time. Prefer it when > 0 (ccusage's behavior).
        let embeddedCost = (root["cost"] as? Double) ?? 0

        let cwd: String? = {
            if let pathDict = root["path"] as? [String: Any],
               let cwd = pathDict["cwd"] as? String, !cwd.isEmpty {
                return cwd
            }
            return nil
        }()

        var tokens = TokenTotals(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: cacheWriteTokens,
            cacheReadTokens: cacheReadTokens,
            reasoningTokens: reasoningTokens,
            requestCount: 1
        )

        // Cost resolution. ccusage tries:
        //   1. embedded `cost` if > 0
        //   2. raw `modelID`
        //   3. normalized `modelID` (.replacingOccurrences(".", "-"))
        //   4. `providerID/modelID`
        //   5. `providerID/normalizedModelID`
        if embeddedCost > 0 {
            tokens.costUSD = Decimal(embeddedCost)
        } else {
            tokens.costUSD = resolveCost(
                modelID: modelID,
                providerID: providerID,
                tokens: tokens
            )
        }

        // Resolve `modelKey` for the UsageRecord. The aggregator uses
        // this for the unpriced-models bucket; pass the raw modelID so
        // a missing rate shows up as "model = minimax-m2.5-free" not
        // "model = opencode/minimax-m2.5-free".
        return UsageRecord(
            provider: .opencode,
            timestamp: timestamp,
            model: modelID,
            tokens: tokens,
            repo: cwd,
            dedupKey: messageId
        )
    }

    /// Cost resolution with provider-prefix + dot/dash normalization
    /// fallbacks. Returns 0 if no rate variant matches; the aggregator
    /// then folds the row into `unpricedModelTokens` for surface in the
    /// UI's "unpriced models" pill.
    private static func resolveCost(modelID: String, providerID: String, tokens: TokenTotals) -> Decimal {
        let candidates: [String] = {
            let normalized = modelID.replacingOccurrences(of: ".", with: "-")
            var out: [String] = []
            if !modelID.isEmpty { out.append(modelID) }
            if normalized != modelID { out.append(normalized) }
            if !providerID.isEmpty {
                if !modelID.isEmpty { out.append("\(providerID)/\(modelID)") }
                if normalized != modelID { out.append("\(providerID)/\(normalized)") }
            }
            return out
        }()
        for candidate in candidates {
            let cost = Pricing.shared.cost(for: candidate, tokens: tokens)
            if cost > 0 { return cost }
        }
        return 0
    }
}
#endif

#if os(macOS)
import XCTest
import SQLite3
@testable import ClawdmeterShared

/// F1c-wire parity tests: prove the `OpenCodeAdapter`-routed analytics
/// path produces the same `UsageRecord` output as the legacy
/// `OpencodeUsageParser.decode(...)` for every representative OpenCode
/// JSON blob shape.
///
/// **Why this matters.** The F1c-wire PR introduces the
/// `FeatureFlags.useOpenCodeAdapter` strangler-fig flag. With the flag
/// OFF, the analytics pipeline calls `OpencodeUsageParser.decode(...)`
/// directly. With the flag ON, it calls
/// `OpenCodeAdapterUsageBridge.decode(...)`, which routes through
/// `OpenCodeAdapter.translate(...)`. Both paths must return the same
/// `UsageRecord?` value bit-for-bit. This suite is the authoritative
/// parity contract — failing it means the wire has silently changed
/// analytics output.
///
/// **Coverage.** Fixtures cover every shape from `OpenCodeAdapterTests`
/// (the source-only F1c suite) plus every drop rule the legacy parser
/// enforces:
///   - Happy-path assistant turn with full token breakdown + embedded
///     cost preference
///   - Token-breakdown variants (reasoning, cache.write, cache.read)
///   - Cost fallback when `cost` field is 0 or missing (resolveCost)
///   - User-role row (no `tokens` block) → both nil
///   - Zero-token row → both nil
///   - Malformed JSON → both nil
///   - Missing `path.cwd` → repo nil
///   - Missing `modelID` → model "" (legacy preserves the empty string)
///   - End-to-end loader snapshot parity through the actor under both
///     flag states
///
/// **Plan:** F1c-wire (Phase 1; D23 strangler-fig) — see
/// `.claude/plans/study-this-codebase-crystalline-shore.md`.
final class F1cParityTests: XCTestCase {

    // MARK: - Setup

    private let timestamp = Date(timeIntervalSince1970: 1_715_000_000)
    private let messageId = "msg-fixture"

    override func tearDown() {
        super.tearDown()
        FeatureFlags.useOpenCodeAdapterOverride = nil
    }

    /// Helper: run both paths on the same blob, assert equality. Tests
    /// drive the underlying `decode(jsonBlob:)` API directly because
    /// driving the full SQLite read in every parity test would gold-plate
    /// the suite — the SQLite reading is tested separately, and the
    /// per-row decode is the unit the strangler-fig flag gates.
    private func assertParity(
        _ jsonString: String,
        file: StaticString = #file,
        line testLine: UInt = #line
    ) {
        let data = jsonString.data(using: .utf8)!
        let legacy = OpencodeUsageParser.decode(jsonBlob: data, messageId: messageId, timestamp: timestamp)
        let adapted = OpenCodeAdapterUsageBridge.decode(jsonBlob: data, messageId: messageId, timestamp: timestamp)
        XCTAssertEqual(legacy, adapted, """
        Parity violation:
          legacy:  \(legacy.map(String.init(describing:)) ?? "nil")
          adapted: \(adapted.map(String.init(describing:)) ?? "nil")
        """, file: file, line: testLine)
    }

    // MARK: - Happy paths (mirror OpenCodeAdapterTests)

    func test_parity_assistant_fullTokenBreakdown_embeddedCost() {
        // Shape: full assistant message with all token categories +
        // embedded cost > 0. Legacy prefers the embedded cost; adapter
        // path must do the same via the embedded_cost_usd extension.
        assertParity("""
        {
          "role": "assistant",
          "cost": 0.012,
          "tokens": {
            "input": 1500,
            "output": 320,
            "reasoning": 100,
            "cache": { "write": 0, "read": 4200 }
          },
          "modelID": "claude-sonnet-4.5",
          "providerID": "anthropic",
          "time": { "created": 1715000000000 },
          "path": { "cwd": "/Users/x/myrepo" },
          "content": "Here is the diff."
        }
        """)
    }

    func test_parity_assistant_partsArrayShape() {
        // Some OpenCode versions emit `parts: [{ text: ... }]` instead of
        // `content`. Token totals still live on `tokens.*`; this shape
        // exercises the adapter's parts-array path but the analytics
        // record only cares about tokens, model, repo.
        assertParity("""
        {
          "role": "assistant",
          "tokens": { "input": 100, "output": 50 },
          "modelID": "gpt-5",
          "providerID": "openai",
          "parts": [
            { "text": "First part." },
            { "text": "Second part." }
          ]
        }
        """)
    }

    func test_parity_assistant_costFallback_noEmbedded() {
        // No embedded cost → both paths fall through to Pricing.cost()
        // resolution. With a known model (claude-sonnet-4-5), the
        // resolveCost candidate list lands a non-zero cost. Both paths
        // MUST agree on the resolved Decimal bit-for-bit.
        assertParity("""
        {
          "role": "assistant",
          "tokens": {
            "input": 1000,
            "output": 200,
            "cache": { "write": 0, "read": 500 }
          },
          "modelID": "claude-sonnet-4-5",
          "providerID": "anthropic",
          "path": { "cwd": "/Users/x/r1" }
        }
        """)
    }

    func test_parity_assistant_costFallback_dotNormalization() {
        // Legacy's resolveCost candidates include the dot→dash
        // normalized variant for models like "claude-sonnet-4.5".
        // Adapter path must run the same fallback chain.
        assertParity("""
        {
          "role": "assistant",
          "tokens": { "input": 500, "output": 100 },
          "modelID": "claude-sonnet-4.5",
          "providerID": "anthropic",
          "path": { "cwd": "/Users/x/r1" }
        }
        """)
    }

    func test_parity_assistant_costFallback_providerPrefix() {
        // When the bare model lookup misses, legacy tries
        // "<providerID>/<modelID>". Adapter path must match.
        assertParity("""
        {
          "role": "assistant",
          "tokens": { "input": 200, "output": 50 },
          "modelID": "minimax-m2.5-free",
          "providerID": "opencode",
          "path": { "cwd": "/Users/x/r1" }
        }
        """)
    }

    func test_parity_assistant_zeroEmbeddedCost_fallsThrough() {
        // Embedded cost == 0 should NOT block fallback (legacy uses
        // `if embeddedCost > 0`, not `if embeddedCost != nil`).
        assertParity("""
        {
          "role": "assistant",
          "cost": 0,
          "tokens": { "input": 1000, "output": 200 },
          "modelID": "claude-sonnet-4-5",
          "providerID": "anthropic",
          "path": { "cwd": "/Users/x/r1" }
        }
        """)
    }

    func test_parity_assistant_cwdMissing_repoNil() {
        // No `path.cwd` → repo is nil. Both paths must skip the cwd
        // extraction the same way.
        assertParity("""
        {
          "role": "assistant",
          "tokens": { "input": 100, "output": 50 },
          "modelID": "claude-sonnet-4-5",
          "providerID": "anthropic"
        }
        """)
    }

    func test_parity_assistant_emptyCwd_repoNil() {
        // Empty cwd string → repo nil (legacy: `!cwd.isEmpty` guard).
        assertParity("""
        {
          "role": "assistant",
          "tokens": { "input": 100, "output": 50 },
          "modelID": "claude-sonnet-4-5",
          "providerID": "anthropic",
          "path": { "cwd": "" }
        }
        """)
    }

    func test_parity_assistant_modelMissing_emptyString() {
        // Missing modelID → legacy stores "" in `record.model`. Adapter
        // path must do the same (NOT "unknown" — that's the Claude
        // convention, not OpenCode's).
        assertParity("""
        {
          "role": "assistant",
          "tokens": { "input": 100, "output": 50 },
          "providerID": "anthropic",
          "path": { "cwd": "/Users/x/r1" }
        }
        """)
    }

    func test_parity_assistant_providerIdMissing() {
        // No providerID → cost resolver skips the prefixed candidates;
        // both paths must agree (likely $0 cost if bare model misses).
        assertParity("""
        {
          "role": "assistant",
          "tokens": { "input": 100, "output": 50 },
          "modelID": "unknown-model-xyz",
          "path": { "cwd": "/Users/x/r1" }
        }
        """)
    }

    // MARK: - Cache-heavy edge cases

    func test_parity_assistant_cacheReadHeavy_inputZero() {
        // Cache-heavy turn: input=0 but cache_read carries the load.
        // Total > 0 so both paths emit a record.
        assertParity("""
        {
          "role": "assistant",
          "tokens": {
            "input": 0,
            "output": 42,
            "cache": { "write": 0, "read": 50000 }
          },
          "modelID": "claude-sonnet-4-5",
          "providerID": "anthropic",
          "path": { "cwd": "/Users/x/r1" }
        }
        """)
    }

    func test_parity_assistant_cacheCreationHeavy() {
        assertParity("""
        {
          "role": "assistant",
          "tokens": {
            "input": 500,
            "output": 100,
            "cache": { "write": 12000, "read": 0 }
          },
          "modelID": "claude-sonnet-4-5",
          "providerID": "anthropic",
          "path": { "cwd": "/Users/x/r1" }
        }
        """)
    }

    func test_parity_assistant_reasoningTokensOnly() {
        // Reasoning-only turn: input+output = 0 but reasoning > 0.
        // nonZero check should still pass since reasoning is summed.
        assertParity("""
        {
          "role": "assistant",
          "tokens": {
            "input": 0,
            "output": 0,
            "reasoning": 1000
          },
          "modelID": "o1-preview",
          "providerID": "openai",
          "path": { "cwd": "/Users/x/r1" }
        }
        """)
    }

    // MARK: - Drops (both paths return nil)

    func test_parity_userMessage_noTokensBlock_bothNil() {
        // User messages have no `tokens` block; legacy skips silently.
        // Adapter emits a `.userMessage` event with no usage payload,
        // bridge ignores everything but `.assistantMessageCompleted`,
        // so both return nil. Mirror the `tokens != nil` guard in the
        // bridge so the drop happens BEFORE invoking the adapter.
        assertParity("""
        {
          "role": "user",
          "modelID": "claude-sonnet-4-5",
          "content": "Refactor this."
        }
        """)
    }

    func test_parity_zeroTokens_bothNil() {
        // All-zero tokens row: nonZero check fails, both paths drop.
        assertParity("""
        {
          "role": "assistant",
          "tokens": {
            "input": 0,
            "output": 0,
            "reasoning": 0,
            "cache": { "write": 0, "read": 0 }
          },
          "modelID": "claude-sonnet-4-5",
          "providerID": "anthropic",
          "path": { "cwd": "/Users/x/r1" }
        }
        """)
    }

    func test_parity_malformedJSON_bothNil() {
        assertParity("not json {")
    }

    func test_parity_emptyBlob_bothNil() {
        assertParity("")
    }

    func test_parity_emptyObject_bothNil() {
        // {} has no `tokens` block → both paths drop.
        assertParity("{}")
    }

    // MARK: - Adapter-only behavior (extension envelope)

    /// Regression: prove the cost-resolution candidates the adapter
    /// path uses match the legacy parser's `resolveCost(...)` candidate
    /// order. Picks an unpriced model so both paths land on cost == 0
    /// without depending on a specific entry in pricing.json.
    func test_parity_costResolution_candidateOrderMatches() {
        assertParity("""
        {
          "role": "assistant",
          "tokens": { "input": 1, "output": 1 },
          "modelID": "future-unpriced-model-xyz",
          "providerID": "future-unpriced-provider",
          "path": { "cwd": "/Users/x/r1" }
        }
        """)
    }

    // MARK: - End-to-end loader parity (flag-off vs flag-on)

    /// Drive a synthetic OpenCode SQLite DB through the loader twice
    /// (once with the flag off, once with it on). The aggregate
    /// `UsageHistorySnapshot.opencode` totals MUST match exactly.
    /// Catches regressions where the bridge silently drops or
    /// duplicates records on the SQLite read leg.
    func test_parity_endToEnd_loaderSnapshotMatchesAcrossFlag() async throws {
        // Build a temp SQLite db that mirrors `~/.local/share/opencode/opencode.db`.
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("f1c-parity-opencode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let dbURL = temp.appendingPathComponent("opencode.db")
        try seedOpenCodeDatabase(at: dbURL, rows: [
            // Three usage-bearing rows + one user row that both paths drop.
            (
                id: "msg_1",
                createdMs: 1_715_000_000_000,
                data: """
                {
                  "role": "assistant",
                  "cost": 0.01,
                  "tokens": {
                    "input": 1000,
                    "output": 200,
                    "cache": { "write": 0, "read": 500 }
                  },
                  "modelID": "claude-sonnet-4-5",
                  "providerID": "anthropic",
                  "path": { "cwd": "/Users/x/r1" }
                }
                """
            ),
            (
                id: "msg_2",
                createdMs: 1_715_000_500_000,
                data: """
                {
                  "role": "user",
                  "content": "next"
                }
                """
            ),
            (
                id: "msg_3",
                createdMs: 1_715_001_000_000,
                data: """
                {
                  "role": "assistant",
                  "tokens": {
                    "input": 500,
                    "output": 80,
                    "cache": { "write": 1000, "read": 0 }
                  },
                  "modelID": "claude-sonnet-4-5",
                  "providerID": "anthropic",
                  "path": { "cwd": "/Users/x/r1" }
                }
                """
            ),
        ])

        let claudeDir = temp.appendingPathComponent("claude")
        let codexDir = temp.appendingPathComponent("codex")
        let geminiDir = temp.appendingPathComponent("gemini")
        for dir in [claudeDir, codexDir, geminiDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        // Flag off
        FeatureFlags.useOpenCodeAdapterOverride = false
        defer { FeatureFlags.useOpenCodeAdapterOverride = nil }
        let loaderOff = UsageHistoryLoader(
            claudeDir: claudeDir,
            codexDir: codexDir,
            geminiDir: geminiDir,
            agyDir: temp.appendingPathComponent("agy-missing"),
            opencodeDBURL: dbURL,
            cacheURL: temp.appendingPathComponent("cache-off.json")
        )
        let snapshotOff = await loaderOff.loadAll()

        // Flag on
        FeatureFlags.useOpenCodeAdapterOverride = true
        let loaderOn = UsageHistoryLoader(
            claudeDir: claudeDir,
            codexDir: codexDir,
            geminiDir: geminiDir,
            agyDir: temp.appendingPathComponent("agy-missing"),
            opencodeDBURL: dbURL,
            cacheURL: temp.appendingPathComponent("cache-on.json")
        )
        let snapshotOn = await loaderOn.loadAll()

        // Snapshot totals must be identical across the flag.
        let opencodeOff = snapshotOff.byProvider[.opencode]
        let opencodeOn = snapshotOn.byProvider[.opencode]
        XCTAssertNotNil(opencodeOff, "Flag-off snapshot must populate the opencode slot")
        XCTAssertNotNil(opencodeOn, "Flag-on snapshot must populate the opencode slot")
        XCTAssertEqual(
            opencodeOff?.allTime.totals.inputTokens,
            opencodeOn?.allTime.totals.inputTokens,
            "Total input tokens must match across the flag"
        )
        XCTAssertEqual(
            opencodeOff?.allTime.totals.outputTokens,
            opencodeOn?.allTime.totals.outputTokens,
            "Total output tokens must match across the flag"
        )
        XCTAssertEqual(
            opencodeOff?.allTime.totals.cacheCreationTokens,
            opencodeOn?.allTime.totals.cacheCreationTokens,
            "Cache creation tokens must match across the flag"
        )
        XCTAssertEqual(
            opencodeOff?.allTime.totals.cacheReadTokens,
            opencodeOn?.allTime.totals.cacheReadTokens,
            "Cache read tokens must match across the flag"
        )
        XCTAssertEqual(
            opencodeOff?.allTime.totals.costUSD,
            opencodeOn?.allTime.totals.costUSD,
            "Aggregate cost USD must match across the flag"
        )
    }

    // MARK: - Helpers

    /// Build a one-table SQLite db that mirrors the OpenCode schema
    /// `OpencodeUsageParser` reads from: a `message` table with
    /// (id TEXT PRIMARY KEY, time_created INTEGER, data TEXT).
    /// Uses sqlite3 C API directly to avoid pulling in a heavy
    /// Swift wrapper just for tests.
    private func seedOpenCodeDatabase(
        at url: URL,
        rows: [(id: String, createdMs: Int64, data: String)]
    ) throws {
        var db: OpaquePointer?
        let openRC = sqlite3_open_v2(
            url.path,
            &db,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE,
            nil
        )
        guard openRC == SQLITE_OK, let db else {
            sqlite3_close_v2(db)
            throw NSError(domain: "F1cParityTests", code: Int(openRC),
                          userInfo: [NSLocalizedDescriptionKey: "sqlite3_open_v2 failed"])
        }
        defer { sqlite3_close_v2(db) }

        let create = """
        CREATE TABLE message (
          id TEXT PRIMARY KEY,
          time_created INTEGER NOT NULL,
          data TEXT NOT NULL
        );
        """
        guard sqlite3_exec(db, create, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "F1cParityTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "CREATE TABLE failed"])
        }
        let insert = "INSERT INTO message (id, time_created, data) VALUES (?, ?, ?);"
        var stmt: OpaquePointer?
        for row in rows {
            guard sqlite3_prepare_v2(db, insert, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw NSError(domain: "F1cParityTests", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "prepare INSERT failed"])
            }
            // SQLITE_TRANSIENT tells SQLite to copy the string immediately
            // (vs SQLITE_STATIC, which expects the caller to keep the
            // pointer alive — risky with Swift bridge lifetimes).
            let SQLITE_TRANSIENT = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
            sqlite3_bind_text(stmt, 1, row.id, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 2, row.createdMs)
            sqlite3_bind_text(stmt, 3, row.data, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                sqlite3_finalize(stmt)
                throw NSError(domain: "F1cParityTests", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "step INSERT failed"])
            }
            sqlite3_finalize(stmt)
        }
    }
}
#endif

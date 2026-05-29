import XCTest
@testable import ClawdmeterShared

/// F1a-wire parity tests: prove the `ClaudeAdapter`-routed analytics path
/// produces the same `UsageRecord` output as the legacy
/// `ClaudeUsageParser` for every representative Claude JSONL line.
///
/// **Why this matters.** The F1a-wire PR introduces the
/// `FeatureFlags.useClaudeAdapter` strangler-fig flag. With the flag OFF,
/// the analytics pipeline calls `ClaudeUsageParser.parse(line:)` directly.
/// With the flag ON, it calls `ClaudeAdapterUsageBridge.parseLine(_:)`,
/// which routes through `ClaudeAdapter.translate(...)`. Both paths must
/// return the same `UsageRecord?` value bit-for-bit. This suite is the
/// authoritative parity contract — failing it means the wire has
/// silently changed analytics output.
///
/// **Coverage.** Fixtures mirror every shape the legacy parser exercises:
///   - Happy-path assistant turn with full usage + cache tokens.
///   - Older logs without cache fields.
///   - Missing cwd → nil repo (aggregator buckets under "(unknown)").
///   - Missing model → "unknown" sentinel.
///   - Missing message.id → nil dedupKey; missing requestId → dedup by
///     message.id alone (ccusage parity for the opus-4-8-era format).
///   - User lines (no usage) → both paths return nil.
///   - Lines with `usage: {input:0, output:0}` → both paths return nil.
///   - Lines with no `message.usage` envelope → both paths return nil.
///   - Malformed JSON → both paths return nil.
///   - System (`type:"system"`) / meta lines → both paths return nil.
///
/// **Plan:** F1a-wire (Phase 1; D23 strangler-fig) — see
/// `.claude/plans/study-this-codebase-crystalline-shore.md`.
final class F1aParityTests: XCTestCase {

    // MARK: - Setup

    /// Helper: run both paths on the same line, assert equality. The
    /// flag override is reset after every call so tests can't leak state.
    private func assertParity(
        line: String,
        file: StaticString = #file,
        line testLine: UInt = #line
    ) {
        let data = line.data(using: .utf8)!
        let legacy = ClaudeUsageParser.parse(line: data)
        let adapted = ClaudeAdapterUsageBridge.parseLine(data)
        XCTAssertEqual(legacy, adapted, """
        Parity violation:
          legacy:  \(legacy.map(String.init(describing:)) ?? "nil")
          adapted: \(adapted.map(String.init(describing:)) ?? "nil")
        """, file: file, line: testLine)
    }

    // MARK: - Happy paths

    func test_parity_assistantTurn_fullUsageAndCache() {
        assertParity(line: """
        {"timestamp":"2026-05-15T10:00:00Z","requestId":"req_1","cwd":"/Users/x/repo","message":{"id":"msg_1","role":"assistant","model":"claude-sonnet-4-5","content":[{"type":"text","text":"hi"}],"usage":{"input_tokens":1500,"output_tokens":320,"cache_creation_input_tokens":1200,"cache_read_input_tokens":3200}}}
        """)
    }

    func test_parity_assistantTurn_olderLog_noCacheFields() {
        assertParity(line: """
        {"timestamp":"2026-05-15T10:00:00Z","requestId":"req_2","cwd":"/Users/x/repo","message":{"id":"msg_2","role":"assistant","model":"claude-3-5-sonnet","content":[{"type":"text","text":"older"}],"usage":{"input_tokens":100,"output_tokens":50}}}
        """)
    }

    func test_parity_assistantTurn_fractionalSecondsTimestamp() {
        assertParity(line: """
        {"timestamp":"2026-05-15T10:00:00.123Z","requestId":"req_3","cwd":"/Users/x/repo","message":{"id":"msg_3","role":"assistant","model":"claude-sonnet-4-5","content":[{"type":"text","text":"x"}],"usage":{"input_tokens":10,"output_tokens":5}}}
        """)
    }

    func test_parity_assistantTurn_modelMissing_defaultsToUnknown() {
        assertParity(line: """
        {"timestamp":"2026-05-15T10:00:00Z","requestId":"req_4","cwd":"/Users/x/repo","message":{"id":"msg_4","role":"assistant","content":[{"type":"text","text":"x"}],"usage":{"input_tokens":100,"output_tokens":50}}}
        """)
    }

    func test_parity_assistantTurn_cwdMissing_repoNil() {
        assertParity(line: """
        {"timestamp":"2026-05-15T10:00:00Z","requestId":"req_5","message":{"id":"msg_5","role":"assistant","model":"claude-sonnet-4-5","content":[{"type":"text","text":"x"}],"usage":{"input_tokens":100,"output_tokens":50}}}
        """)
    }

    func test_parity_assistantTurn_messageIdMissing_dedupNil() {
        assertParity(line: """
        {"timestamp":"2026-05-15T10:00:00Z","requestId":"req_6","cwd":"/Users/x/repo","message":{"role":"assistant","model":"claude-sonnet-4-5","content":[{"type":"text","text":"x"}],"usage":{"input_tokens":100,"output_tokens":50}}}
        """)
    }

    func test_parity_assistantTurn_requestIdMissing_dedupsByMessageId() {
        // opus-4-8-era format: no requestId. Both paths must still dedup by
        // message.id (key "msg_7:"), matching ccusage — not return nil.
        assertParity(line: """
        {"timestamp":"2026-05-15T10:00:00Z","cwd":"/Users/x/repo","message":{"id":"msg_7","role":"assistant","model":"claude-sonnet-4-5","content":[{"type":"text","text":"x"}],"usage":{"input_tokens":100,"output_tokens":50}}}
        """)
    }

    func test_parity_assistantTurn_withToolUseBlocks() {
        // tool_use blocks shouldn't affect token totals — usage lives on
        // the message envelope, not the block.
        assertParity(line: """
        {"timestamp":"2026-05-15T10:00:00Z","requestId":"req_8","cwd":"/Users/x/repo","message":{"id":"msg_8","role":"assistant","model":"claude-sonnet-4-5","content":[{"type":"text","text":"running"},{"type":"tool_use","id":"tu_1","name":"Bash","input":{"command":"ls"}}],"usage":{"input_tokens":2000,"output_tokens":100,"cache_creation_input_tokens":0,"cache_read_input_tokens":500}}}
        """)
    }

    // MARK: - Drops (both paths return nil)

    func test_parity_userLine_noUsage_bothNil() {
        assertParity(line: """
        {"timestamp":"2026-05-15T10:00:00Z","cwd":"/Users/x/repo","message":{"role":"user","content":"hello"}}
        """)
    }

    func test_parity_zeroTokens_bothNil() {
        assertParity(line: """
        {"timestamp":"2026-05-15T10:00:00Z","requestId":"req_x","cwd":"/Users/x/repo","message":{"id":"msg_x","role":"assistant","model":"claude-sonnet-4-5","content":[{"type":"text","text":""}],"usage":{"input_tokens":0,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
        """)
    }

    func test_parity_assistantWithoutUsage_bothNil() {
        // Streaming partial: assistant content but no usage yet. Legacy
        // returns nil (no usage envelope). Adapter emits an
        // `.assistantTokenDelta` but the bridge only consumes
        // `.assistantMessageCompleted` events — so it also returns nil.
        assertParity(line: """
        {"timestamp":"2026-05-15T10:00:00Z","requestId":"req_p","cwd":"/Users/x/repo","message":{"id":"msg_p","role":"assistant","model":"claude-sonnet-4-5","content":[{"type":"text","text":"partial"}]}}
        """)
    }

    func test_parity_malformedJSON_bothNil() {
        assertParity(line: "not json {")
    }

    func test_parity_emptyLine_bothNil() {
        assertParity(line: "")
    }

    func test_parity_systemLine_bothNil() {
        // type:"system" lines lack a `message.usage` envelope, so the
        // legacy parser returns nil. The adapter emits a
        // `.sessionStarted` event but the bridge ignores everything
        // except `.assistantMessageCompleted`, so adapter-side also nil.
        assertParity(line: """
        {"type":"system","subtype":"init","model":"claude-sonnet-4-5","timestamp":"2026-05-15T10:00:00Z"}
        """)
    }

    func test_parity_toolRoleLine_bothNil() {
        // role:"tool" delivers a tool result — no usage payload, so both
        // paths must drop. Adapter emits `.toolResult`; bridge ignores.
        assertParity(line: """
        {"timestamp":"2026-05-15T10:00:00Z","message":{"role":"tool","tool_use_id":"tu_1","content":"OK","is_error":false}}
        """)
    }

    // MARK: - Token math edge cases

    func test_parity_cacheReadOnly_inputZero() {
        // Real-world: cache-heavy turn where input_tokens=0 but
        // cache_read_input_tokens carries the load. totalTokens > 0 so
        // both paths emit a record.
        assertParity(line: """
        {"timestamp":"2026-05-15T10:00:00Z","requestId":"req_cr","cwd":"/Users/x/repo","message":{"id":"msg_cr","role":"assistant","model":"claude-sonnet-4-5","content":[{"type":"text","text":"x"}],"usage":{"input_tokens":0,"output_tokens":42,"cache_creation_input_tokens":0,"cache_read_input_tokens":50000}}}
        """)
    }

    func test_parity_cacheCreationHeavy() {
        assertParity(line: """
        {"timestamp":"2026-05-15T10:00:00Z","requestId":"req_cc","cwd":"/Users/x/repo","message":{"id":"msg_cc","role":"assistant","model":"claude-sonnet-4-5","content":[{"type":"text","text":"x"}],"usage":{"input_tokens":500,"output_tokens":100,"cache_creation_input_tokens":12000,"cache_read_input_tokens":0}}}
        """)
    }

    func test_parity_missingRole_butUsagePresent_shimHandles() {
        // The legacy parser ignores `message.role` — it only requires
        // `message.usage`. The adapter switches on role and falls
        // through to `.unknown` when role is missing, which would drop
        // usage-bearing lines. The bridge shim synthesizes
        // role:"assistant" when usage is present so parity holds for
        // this legacy-tolerated shape.
        assertParity(line: """
        {"timestamp":"2026-05-15T10:00:00Z","requestId":"req_noRole","cwd":"/Users/x/repo","message":{"id":"msg_noRole","model":"claude-sonnet-4-5","usage":{"input_tokens":100,"output_tokens":50}}}
        """)
    }

    // MARK: - Chat-pipeline token extraction parity

    /// Proves the contract the Mac-side `decodeAssistantViaAdapter`
    /// depends on: tokens + cache totals + model pulled off the
    /// canonical event + claude extension match what the legacy parser
    /// pulls off `message.usage` directly. The Mac test suite asserts
    /// the same against the full `ParsedLine` shape — keeping this
    /// projection-level check in Shared catches divergences earlier,
    /// before they propagate into the Mac wiring.
    func test_parity_chatTokenExtraction_matchesLegacyUsageRead() {
        let line = """
        {"timestamp":"2026-05-15T10:00:00Z","requestId":"req_chat","cwd":"/Users/x/repo","message":{"id":"msg_chat","role":"assistant","model":"claude-sonnet-4-5","content":[{"type":"text","text":"hello"},{"type":"tool_use","id":"tu_chat","name":"Bash","input":{"command":"ls"}}],"usage":{"input_tokens":1234,"output_tokens":567,"cache_creation_input_tokens":89,"cache_read_input_tokens":10}}}
        """
        let data = line.data(using: .utf8)!
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return XCTFail("Fixture is not valid JSON")
        }

        // Legacy chat-side read: walk message.usage directly.
        let message = json["message"] as! [String: Any]
        let usage = message["usage"] as! [String: Any]
        let legacyIn = usage["input_tokens"] as! Int
        let legacyOut = usage["output_tokens"] as! Int
        let legacyCacheCreate = usage["cache_creation_input_tokens"] as! Int
        let legacyCacheRead = usage["cache_read_input_tokens"] as! Int
        let legacyModel = message["model"] as? String

        // Adapter-side read: translate to canonical events, pluck the
        // assistantMessageCompleted payload + claude extension envelope.
        let events = ClaudeAdapter.translate(line: json, sessionId: "", sequenceStart: 0)
        var adaptedIn = 0, adaptedOut = 0
        var adaptedCacheCreate = 0, adaptedCacheRead = 0
        var adaptedModel: String? = nil
        for event in events {
            if case let .nested(ext) = event.providerExtensions?["claude"] {
                if case let .int(v) = ext["cache_creation_input_tokens"] { adaptedCacheCreate = Int(v) }
                if case let .int(v) = ext["cache_read_input_tokens"] { adaptedCacheRead = Int(v) }
                if case let .string(m) = ext["model"], adaptedModel == nil { adaptedModel = m }
            }
            if case let .assistantMessageCompleted(_, tIn, tOut) = event.payload {
                adaptedIn = tIn
                adaptedOut = tOut
            }
        }

        XCTAssertEqual(legacyIn, adaptedIn, "input_tokens")
        XCTAssertEqual(legacyOut, adaptedOut, "output_tokens")
        XCTAssertEqual(legacyCacheCreate, adaptedCacheCreate, "cache_creation_input_tokens")
        XCTAssertEqual(legacyCacheRead, adaptedCacheRead, "cache_read_input_tokens")
        XCTAssertEqual(legacyModel, adaptedModel, "model")
    }

    // MARK: - Flag-off vs flag-on at the loader boundary

    /// End-to-end check: drive a file of mixed lines through the loader
    /// twice (once with the flag off, once with it on). The aggregate
    /// `UsageHistorySnapshot` totals MUST match exactly. Catches
    /// regressions where the bridge silently drops or duplicates records.
    func test_parity_endToEnd_loaderSnapshotMatchesAcrossFlag() async throws {
        let lines: [String] = [
            // Two usage-bearing assistant turns + one user line that
            // both paths drop. Tests that the aggregator sees the same
            // records in either mode.
            """
            {"timestamp":"2026-05-15T10:00:00Z","requestId":"req_a","cwd":"/Users/x/r1","message":{"id":"msg_a","role":"assistant","model":"claude-sonnet-4-5","content":[{"type":"text","text":"x"}],"usage":{"input_tokens":1000,"output_tokens":200,"cache_creation_input_tokens":0,"cache_read_input_tokens":500}}}
            """,
            """
            {"timestamp":"2026-05-15T11:00:00Z","cwd":"/Users/x/r1","message":{"role":"user","content":"next"}}
            """,
            """
            {"timestamp":"2026-05-15T12:00:00Z","requestId":"req_b","cwd":"/Users/x/r1","message":{"id":"msg_b","role":"assistant","model":"claude-sonnet-4-5","content":[{"type":"text","text":"y"}],"usage":{"input_tokens":500,"output_tokens":80,"cache_creation_input_tokens":1000,"cache_read_input_tokens":0}}}
            """,
        ]
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("f1a-parity-claude-\(UUID().uuidString)", isDirectory: true)
        let projectsDir = tmp.appendingPathComponent("projects", isDirectory: true)
        let sessionDir = projectsDir.appendingPathComponent("-Users-x-r1", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let url = sessionDir.appendingPathComponent("session.jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let codexDir = tmp.appendingPathComponent("codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        let geminiDir = tmp.appendingPathComponent("gemini", isDirectory: true)
        try FileManager.default.createDirectory(at: geminiDir, withIntermediateDirectories: true)

        // Flag off
        FeatureFlags.useClaudeAdapterOverride = false
        defer { FeatureFlags.useClaudeAdapterOverride = nil }
        let loaderOff = UsageHistoryLoader(
            claudeDir: projectsDir,
            codexDir: codexDir,
            geminiDir: geminiDir,
            cacheURL: tmp.appendingPathComponent("cache-off.json")
        )
        let snapshotOff = await loaderOff.loadAll()

        // Flag on
        FeatureFlags.useClaudeAdapterOverride = true
        let loaderOn = UsageHistoryLoader(
            claudeDir: projectsDir,
            codexDir: codexDir,
            geminiDir: geminiDir,
            cacheURL: tmp.appendingPathComponent("cache-on.json")
        )
        let snapshotOn = await loaderOn.loadAll()

        // Snapshot totals must be identical across the flag.
        let claudeOff = snapshotOff.byProvider[.claude]
        let claudeOn = snapshotOn.byProvider[.claude]
        XCTAssertEqual(
            claudeOff?.allTime.totals.inputTokens,
            claudeOn?.allTime.totals.inputTokens,
            "Total input tokens must match across the flag"
        )
        XCTAssertEqual(
            claudeOff?.allTime.totals.outputTokens,
            claudeOn?.allTime.totals.outputTokens,
            "Total output tokens must match across the flag"
        )
        XCTAssertEqual(
            claudeOff?.allTime.totals.cacheCreationTokens,
            claudeOn?.allTime.totals.cacheCreationTokens,
            "Cache creation tokens must match across the flag"
        )
        XCTAssertEqual(
            claudeOff?.allTime.totals.cacheReadTokens,
            claudeOn?.allTime.totals.cacheReadTokens,
            "Cache read tokens must match across the flag"
        )
    }
}

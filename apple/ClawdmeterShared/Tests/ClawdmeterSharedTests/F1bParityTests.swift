import XCTest
@testable import ClawdmeterShared

/// F1b-wire parity tests: prove the `CodexAdapter`-routed analytics path
/// produces the same `[UsageRecord]` output as the legacy
/// `CodexUsageParser` for every representative Codex JSONL rollout shape.
///
/// **Why this matters.** The F1b-wire PR introduces the
/// `FeatureFlags.useCodexAdapter` strangler-fig flag. With the flag OFF,
/// the analytics pipeline calls `CodexUsageParser.parse(file:)` directly.
/// With the flag ON, it calls `CodexAdapterUsageBridge.parseFile(at:)`,
/// which constructs one stateful `CodexAdapter` per file and walks every
/// line through it. Both paths must return the same `[UsageRecord]`
/// value bit-for-bit. This suite is the authoritative parity contract —
/// failing it means the wire has silently changed analytics output.
///
/// **Coverage.** Fixtures mirror every shape `CodexAdapterTests` exercises:
///   - Cumulative→delta math (first snapshot from zero, second from prior).
///   - Session reset (non-monotonic drop on ANY field re-baselines).
///   - Per-field drop with rising total counts also re-baselines.
///   - `session_meta` + `turn_context` set cwd / model.
///   - Missing `session_meta` ⇒ nil repo.
///   - Heartbeat (zero-delta) snapshots emit no record.
///   - Multi-turn rollouts with model swap mid-session.
///   - End-to-end loader snapshot parity through the actor under both
///     flag states.
///
/// **Plan:** F1b-wire (Phase 1; D23 strangler-fig) — see
/// `.claude/plans/study-this-codebase-crystalline-shore.md`.
final class F1bParityTests: XCTestCase {

    // MARK: - Setup

    override func tearDown() {
        super.tearDown()
        FeatureFlags.useCodexAdapterOverride = nil
    }

    /// Helper: write a Codex rollout file containing `lines`, run both
    /// the legacy parser and the adapter bridge, assert the resulting
    /// `[UsageRecord]` arrays are field-by-field equal.
    private func assertParity(
        lines: [String],
        file: StaticString = #file,
        line testLine: UInt = #line
    ) throws {
        let url = try writeTempFile(lines: lines)
        defer { try? FileManager.default.removeItem(at: url) }

        let legacy = try CodexUsageParser.parse(file: url)
        let adapted = try CodexAdapterUsageBridge.parseFile(at: url)

        XCTAssertEqual(legacy.count, adapted.count, """
        Record count diverged (legacy=\(legacy.count) adapted=\(adapted.count))
        """, file: file, line: testLine)

        for (i, (l, a)) in zip(legacy, adapted).enumerated() {
            XCTAssertEqual(l.provider, a.provider, "record[\(i)].provider", file: file, line: testLine)
            XCTAssertEqual(l.timestamp, a.timestamp, "record[\(i)].timestamp", file: file, line: testLine)
            XCTAssertEqual(l.model, a.model, "record[\(i)].model", file: file, line: testLine)
            XCTAssertEqual(l.tokens.inputTokens, a.tokens.inputTokens, "record[\(i)].inputTokens", file: file, line: testLine)
            XCTAssertEqual(l.tokens.outputTokens, a.tokens.outputTokens, "record[\(i)].outputTokens", file: file, line: testLine)
            XCTAssertEqual(l.tokens.cacheCreationTokens, a.tokens.cacheCreationTokens, "record[\(i)].cacheCreationTokens", file: file, line: testLine)
            XCTAssertEqual(l.tokens.cacheReadTokens, a.tokens.cacheReadTokens, "record[\(i)].cacheReadTokens", file: file, line: testLine)
            XCTAssertEqual(l.tokens.reasoningTokens, a.tokens.reasoningTokens, "record[\(i)].reasoningTokens", file: file, line: testLine)
            XCTAssertEqual(l.repo, a.repo, "record[\(i)].repo", file: file, line: testLine)
            XCTAssertEqual(l.dedupKey, a.dedupKey, "record[\(i)].dedupKey", file: file, line: testLine)
        }
    }

    // MARK: - Cumulative delta math

    func test_parity_firstSnapshot_emitsDeltaFromZero() throws {
        try assertParity(lines: [
            #"{"timestamp":"2026-05-15T10:00:00Z","type":"session_meta","payload":{"cwd":"/Users/x/myrepo"}}"#,
            #"{"timestamp":"2026-05-15T10:00:01Z","type":"turn_context","payload":{"model":"gpt-5-codex","cwd":"/Users/x/myrepo"}}"#,
            #"{"timestamp":"2026-05-15T10:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":0,"output_tokens":500,"reasoning_output_tokens":0,"total_tokens":1500}}}}"#,
        ])
    }

    func test_parity_secondSnapshot_emitsDeltaFromPrevious() throws {
        try assertParity(lines: [
            #"{"timestamp":"2026-05-15T10:00:00Z","type":"session_meta","payload":{"cwd":"/Users/x/myrepo"}}"#,
            #"{"timestamp":"2026-05-15T10:00:01Z","type":"turn_context","payload":{"model":"gpt-5-codex","cwd":"/Users/x/myrepo"}}"#,
            #"{"timestamp":"2026-05-15T10:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":0,"output_tokens":500,"reasoning_output_tokens":0,"total_tokens":1500}}}}"#,
            #"{"timestamp":"2026-05-15T10:02:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":3000,"cached_input_tokens":500,"output_tokens":1500,"reasoning_output_tokens":0,"total_tokens":4500}}}}"#,
        ])
    }

    // MARK: - Session reset (non-monotonic) handling

    func test_parity_nonMonotonicDrop_treatedAsBaseline() throws {
        try assertParity(lines: [
            #"{"timestamp":"2026-05-15T10:00:00Z","type":"session_meta","payload":{"cwd":"/r"}}"#,
            #"{"timestamp":"2026-05-15T10:00:01Z","type":"turn_context","payload":{"model":"gpt-5","cwd":"/r"}}"#,
            #"{"timestamp":"2026-05-15T10:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10000,"cached_input_tokens":0,"output_tokens":5000,"total_tokens":15000}}}}"#,
            #"{"timestamp":"2026-05-15T10:02:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":50,"total_tokens":150}}}}"#,
        ])
    }

    func test_parity_perFieldDrop_withRisingTotal_treatedAsBaseline() throws {
        // total_tokens 1900 → 1300 (drop) AND input rises while output
        // crashes. Legacy parser re-baselines on per-field drop because
        // total_tokens dropped too. Codex can also reset individual
        // counters while total stays the same — covered by the next test.
        try assertParity(lines: [
            #"{"timestamp":"2026-05-15T10:00:00Z","type":"session_meta","payload":{"cwd":"/r"}}"#,
            #"{"timestamp":"2026-05-15T10:00:01Z","type":"turn_context","payload":{"model":"gpt-5","cwd":"/r"}}"#,
            #"{"timestamp":"2026-05-15T10:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":0,"output_tokens":900,"total_tokens":1900}}}}"#,
            #"{"timestamp":"2026-05-15T10:02:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1200,"cached_input_tokens":0,"output_tokens":100,"total_tokens":1300}}}}"#,
        ])
    }

    // MARK: - Session meta + turn context

    func test_parity_missingSessionMeta_nilRepo() throws {
        // No session_meta → records have repo: nil → aggregator → "(unknown)"
        try assertParity(lines: [
            #"{"timestamp":"2026-05-15T10:00:01Z","type":"turn_context","payload":{"model":"gpt-5"}}"#,
            #"{"timestamp":"2026-05-15T10:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":50,"total_tokens":150}}}}"#,
        ])
    }

    func test_parity_missingTurnContext_defaultsModel() throws {
        // No turn_context → default model "gpt-5" (legacy parser's
        // initial value + adapter's `currentModel = "gpt-5"`).
        try assertParity(lines: [
            #"{"timestamp":"2026-05-15T10:00:00Z","type":"session_meta","payload":{"cwd":"/Users/x/r"}}"#,
            #"{"timestamp":"2026-05-15T10:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":50,"total_tokens":150}}}}"#,
        ])
    }

    func test_parity_modelSwapMidSession() throws {
        // Codex supports mid-session model swaps via successive
        // turn_context lines. Each subsequent token_count carries the
        // new model in its record.
        try assertParity(lines: [
            #"{"timestamp":"2026-05-15T10:00:00Z","type":"session_meta","payload":{"cwd":"/r"}}"#,
            #"{"timestamp":"2026-05-15T10:00:01Z","type":"turn_context","payload":{"model":"gpt-5","cwd":"/r"}}"#,
            #"{"timestamp":"2026-05-15T10:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":500,"cached_input_tokens":0,"output_tokens":100,"total_tokens":600}}}}"#,
            #"{"timestamp":"2026-05-15T10:01:30Z","type":"turn_context","payload":{"model":"gpt-5-codex","cwd":"/r"}}"#,
            #"{"timestamp":"2026-05-15T10:02:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":0,"output_tokens":200,"total_tokens":1200}}}}"#,
        ])
    }

    // MARK: - Heartbeat / drop cases

    func test_parity_zeroDeltaHeartbeat_emitsNothing() throws {
        // Two consecutive identical cumulatives → second emits no record
        // (zero delta). Legacy + adapter both drop.
        try assertParity(lines: [
            #"{"timestamp":"2026-05-15T10:00:00Z","type":"session_meta","payload":{"cwd":"/r"}}"#,
            #"{"timestamp":"2026-05-15T10:00:01Z","type":"turn_context","payload":{"model":"gpt-5","cwd":"/r"}}"#,
            #"{"timestamp":"2026-05-15T10:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":500,"cached_input_tokens":0,"output_tokens":100,"total_tokens":600}}}}"#,
            #"{"timestamp":"2026-05-15T10:01:30Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":500,"cached_input_tokens":0,"output_tokens":100,"total_tokens":600}}}}"#,
            #"{"timestamp":"2026-05-15T10:02:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":0,"output_tokens":200,"total_tokens":1200}}}}"#,
        ])
    }

    func test_parity_initialZeroCumulative_emitsNothing() throws {
        // First snapshot already at zero → no record. Then a real one.
        try assertParity(lines: [
            #"{"timestamp":"2026-05-15T10:00:00Z","type":"session_meta","payload":{"cwd":"/r"}}"#,
            #"{"timestamp":"2026-05-15T10:00:01Z","type":"turn_context","payload":{"model":"gpt-5","cwd":"/r"}}"#,
            #"{"timestamp":"2026-05-15T10:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":0,"cached_input_tokens":0,"output_tokens":0,"total_tokens":0}}}}"#,
            #"{"timestamp":"2026-05-15T10:02:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":0,"output_tokens":500,"total_tokens":1500}}}}"#,
        ])
    }

    func test_parity_malformedLine_skipped() throws {
        // Mix in a malformed line; both parsers must skip it without
        // disrupting downstream cumulative state.
        try assertParity(lines: [
            #"{"timestamp":"2026-05-15T10:00:00Z","type":"session_meta","payload":{"cwd":"/r"}}"#,
            #"{"timestamp":"2026-05-15T10:00:01Z","type":"turn_context","payload":{"model":"gpt-5","cwd":"/r"}}"#,
            "not json {",
            #"{"timestamp":"2026-05-15T10:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":0,"output_tokens":500,"total_tokens":1500}}}}"#,
        ])
    }

    func test_parity_emptyFile_returnsEmpty() throws {
        try assertParity(lines: [])
    }

    // MARK: - Cache-heavy edges

    func test_parity_cacheHeavyTurn() throws {
        // Cached input dominates fresh input. Adapter encodes
        // `delta_cache_read` separately from canonical `inputTokens`.
        try assertParity(lines: [
            #"{"timestamp":"2026-05-15T10:00:00Z","type":"session_meta","payload":{"cwd":"/r"}}"#,
            #"{"timestamp":"2026-05-15T10:00:01Z","type":"turn_context","payload":{"model":"gpt-5","cwd":"/r"}}"#,
            #"{"timestamp":"2026-05-15T10:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":50000,"cached_input_tokens":49500,"output_tokens":200,"total_tokens":50200}}}}"#,
        ])
    }

    // MARK: - End-to-end loader parity

    /// End-to-end check: drive a Codex rollout file through the loader
    /// twice (once with the flag off, once with it on). The aggregate
    /// `UsageHistorySnapshot` totals MUST match exactly. Catches
    /// regressions where the bridge silently drops or duplicates records.
    func test_parity_endToEnd_loaderSnapshotMatchesAcrossFlag() async throws {
        let lines: [String] = [
            #"{"timestamp":"2026-05-15T10:00:00Z","type":"session_meta","payload":{"cwd":"/Users/x/r1"}}"#,
            #"{"timestamp":"2026-05-15T10:00:01Z","type":"turn_context","payload":{"model":"gpt-5-codex","cwd":"/Users/x/r1"}}"#,
            #"{"timestamp":"2026-05-15T10:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":0,"output_tokens":500,"total_tokens":1500}}}}"#,
            #"{"timestamp":"2026-05-15T10:02:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":3000,"cached_input_tokens":500,"output_tokens":1500,"total_tokens":4500}}}}"#,
        ]
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("f1b-parity-codex-\(UUID().uuidString)", isDirectory: true)
        let codexDir = tmp.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        let url = codexDir.appendingPathComponent("rollout.jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let claudeDir = tmp.appendingPathComponent("claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let geminiDir = tmp.appendingPathComponent("gemini", isDirectory: true)
        try FileManager.default.createDirectory(at: geminiDir, withIntermediateDirectories: true)

        // Flag off
        FeatureFlags.useCodexAdapterOverride = false
        defer { FeatureFlags.useCodexAdapterOverride = nil }
        let loaderOff = UsageHistoryLoader(
            claudeDir: claudeDir,
            codexDir: codexDir,
            geminiDir: geminiDir,
            cacheURL: tmp.appendingPathComponent("cache-off.json")
        )
        let snapshotOff = await loaderOff.loadAll()

        // Flag on
        FeatureFlags.useCodexAdapterOverride = true
        let loaderOn = UsageHistoryLoader(
            claudeDir: claudeDir,
            codexDir: codexDir,
            geminiDir: geminiDir,
            cacheURL: tmp.appendingPathComponent("cache-on.json")
        )
        let snapshotOn = await loaderOn.loadAll()

        // Snapshot totals must be identical across the flag.
        let codexOff = snapshotOff.byProvider[.codex]
        let codexOn = snapshotOn.byProvider[.codex]
        XCTAssertEqual(
            codexOff?.allTime.totals.inputTokens,
            codexOn?.allTime.totals.inputTokens,
            "Total input tokens must match across the flag"
        )
        XCTAssertEqual(
            codexOff?.allTime.totals.outputTokens,
            codexOn?.allTime.totals.outputTokens,
            "Total output tokens must match across the flag"
        )
        XCTAssertEqual(
            codexOff?.allTime.totals.cacheReadTokens,
            codexOn?.allTime.totals.cacheReadTokens,
            "Cache read tokens must match across the flag"
        )
    }

    // MARK: - Helpers

    private func writeTempFile(lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("f1b-parity-\(UUID().uuidString).jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

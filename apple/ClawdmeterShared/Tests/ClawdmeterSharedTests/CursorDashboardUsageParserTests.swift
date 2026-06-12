#if os(macOS)
import XCTest
@testable import ClawdmeterShared

final class CursorDashboardUsageParserTests: XCTestCase {
    private func tempDir(_ name: String = UUID().uuidString) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CursorDashboardUsageParserTests", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func test_parseEvent_usesChargedCentsAndTokenBreakdown() throws {
        let event = try decodeEvent("""
        {
          "timestamp": "1781254265050",
          "model": "composer-2.5-fast",
          "chargedCents": 182.8941,
          "tokenUsage": {
            "inputTokens": 599352,
            "outputTokens": 3010,
            "cacheReadTokens": 326848,
            "totalCents": 182.8941
          }
        }
        """)

        let record = try XCTUnwrap(CursorDashboardUsageParser.parseEvent(event))
        XCTAssertEqual(record.provider, .cursor)
        XCTAssertEqual(record.model, "composer-2.5-fast")
        XCTAssertEqual(record.tokens.inputTokens, 599352)
        XCTAssertEqual(record.tokens.outputTokens, 3010)
        XCTAssertEqual(record.tokens.cacheReadTokens, 326848)
        XCTAssertEqual((record.tokens.costUSD as NSDecimalNumber).doubleValue, 1.828941, accuracy: 0.000001)
        XCTAssertNotNil(record.dedupKey)
    }

    func test_tokensWithResolvedCost_prefersEmbeddedDashboardCostOverPricingAlias() {
        let record = UsageRecord(
            provider: .cursor,
            timestamp: Date(timeIntervalSince1970: 1_781_254_265),
            model: "composer-2.5-fast",
            tokens: TokenTotals(
                inputTokens: 599352,
                outputTokens: 3010,
                cacheReadTokens: 326848,
                costUSD: Decimal(string: "1.828941") ?? 0,
                requestCount: 1
            ),
            repo: nil,
            dedupKey: "cursor-dashboard:test"
        )

        let priced = UsageHistoryLoader.tokensWithResolvedCost(record)
        XCTAssertEqual((priced.tokens.costUSD as NSDecimalNumber).doubleValue, 1.828941, accuracy: 0.000001)
        XCTAssertTrue(priced.isPriced)
    }

    func test_usageHistoryLoader_prefersDashboardRecordsOverLocalHookEstimates() async throws {
        let dir = try tempDir()
        let emptyClaude = dir.appendingPathComponent("claude", isDirectory: true)
        let emptyCodex = dir.appendingPathComponent("codex", isDirectory: true)
        let emptyGemini = dir.appendingPathComponent("gemini", isDirectory: true)
        let hooksRoot = dir.appendingPathComponent("cursor-logs", isDirectory: true)
        let hooksLeaf = hooksRoot
            .appendingPathComponent("window", isDirectory: true)
            .appendingPathComponent("output", isDirectory: true)
        let repo = dir.appendingPathComponent("repo", isDirectory: true)
        for url in [emptyClaude, emptyCodex, emptyGemini, hooksLeaf] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        try hookFixture(repoPath: repo.path).write(
            to: hooksLeaf.appendingPathComponent("cursor.hooks.workspaceId-test.log"),
            atomically: true,
            encoding: .utf8
        )

        let cacheURL = dir.appendingPathComponent("cursor-dashboard-usage.json")
        let dashboardRecord = UsageRecord(
            provider: .cursor,
            timestamp: Date(timeIntervalSince1970: 1_781_254_265),
            model: "composer-2.5-fast",
            tokens: TokenTotals(
                inputTokens: 599352,
                outputTokens: 3010,
                cacheReadTokens: 326848,
                costUSD: Decimal(string: "145.58") ?? 0,
                requestCount: 1
            ),
            repo: nil,
            dedupKey: "cursor-dashboard:fixture"
        )
        CursorDashboardUsageParser.writeCache(
            records: [dashboardRecord],
            fetchedAt: Date(),
            to: cacheURL
        )

        let loader = UsageHistoryLoader(
            claudeDir: emptyClaude,
            codexDir: emptyCodex,
            geminiDir: emptyGemini,
            agyDir: nil,
            opencodeDBURL: nil,
            cursorLedgerURL: dir.appendingPathComponent("missing-cursor-acp-usage.jsonl"),
            cursorHooksLogsDir: hooksRoot,
            cursorDashboardUsageEnabled: true,
            cursorDashboardCacheURL: cacheURL,
            cacheURL: dir.appendingPathComponent("analytics-cache.json")
        )

        let snapshot = await loader.loadAll()
        let cursor = try XCTUnwrap(snapshot.byProvider[.cursor])
        XCTAssertEqual((cursor.allTime.totals.costUSD as NSDecimalNumber).doubleValue, 145.58, accuracy: 0.0001)
        XCTAssertEqual(cursor.allTime.totals.totalTokens, 929_210)
        let composer = try XCTUnwrap(snapshot.tokensByModel["cursor/composer-2.5-fast"])
        XCTAssertEqual((composer.costUSD as NSDecimalNumber).doubleValue, 145.58, accuracy: 0.0001)
    }

    func test_liveDashboardUsageMatchesNonTrivialSpendWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["CLAWDMETER_PROBE_CURSOR_DASHBOARD"] == "1" else {
            throw XCTSkip("Set CLAWDMETER_PROBE_CURSOR_DASHBOARD=1 to fetch live Cursor dashboard usage")
        }

        let records = await CursorDashboardUsageParser.loadRecords(cacheTTL: 0)
        let totalCost = records.reduce(Decimal.zero) { $0 + $1.tokens.costUSD }
        print("Cursor dashboard live records: \(records.count); cost: $\((totalCost as NSDecimalNumber).doubleValue)")

        XCTAssertFalse(records.isEmpty)
        XCTAssertGreaterThan((totalCost as NSDecimalNumber).doubleValue, 1)
        XCTAssertTrue(records.contains { $0.model.contains("composer") })
    }

    private func decodeEvent(_ json: String) throws -> CursorDashboardUsageParser.UsageEventDisplay {
        let data = Data(json.utf8)
        return try JSONDecoder().decode(CursorDashboardUsageParser.UsageEventDisplay.self, from: data)
    }

    private func hookFixture(repoPath: String) -> String {
        """
        [2026-06-05T16:32:31.456Z] Hook step requested: stop
        INPUT:
        {
          "conversation_id": "session-1",
          "generation_id": "generation-1",
          "model": "default",
          "status": "completed",
          "input_tokens": 1000,
          "output_tokens": 40,
          "cache_read_tokens": 700,
          "cache_write_tokens": 50,
          "session_id": "session-1",
          "hook_event_name": "stop",
          "workspace_roots": [
            "\(repoPath)"
          ],
          "transcript_path": "\(repoPath)/transcript.jsonl"
        }
        """
    }
}
#endif

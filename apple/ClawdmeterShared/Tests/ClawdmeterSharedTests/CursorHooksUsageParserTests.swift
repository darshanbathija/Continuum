import XCTest
@testable import ClawdmeterShared

final class CursorHooksUsageParserTests: XCTestCase {
    private func tempDir(_ name: String = UUID().uuidString) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CursorHooksUsageParserTests", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func test_parseCursorHookLog_emitsCursorUsageRecordWithSessionModelAndCacheSplit() throws {
        let dir = try tempDir()
        let repo = dir.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        let log = dir.appendingPathComponent("cursor.hooks.workspaceId-test.log")
        try fixtureLog(repoPath: repo.path).write(to: log, atomically: true, encoding: .utf8)

        let records = try CursorHooksUsageParser.parse(file: log)

        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.provider, .cursor)
        XCTAssertEqual(record.model, "composer-2.5")
        XCTAssertEqual(record.repo, repo.path)
        XCTAssertEqual(record.tokens.inputTokens, 250)
        XCTAssertEqual(record.tokens.outputTokens, 40)
        XCTAssertEqual(record.tokens.cacheReadTokens, 700)
        XCTAssertEqual(record.tokens.cacheCreationTokens, 50)
        XCTAssertEqual(record.tokens.totalTokens, 1_040)
        XCTAssertEqual(record.tokens.requestCount, 1)
        XCTAssertEqual(record.tokens.costUSD, 0)
        XCTAssertNotNil(record.dedupKey)
    }

    func test_usageHistoryLoader_includesCursorHookRecordsInProviderAndModelRollups() async throws {
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
        try fixtureLog(repoPath: repo.path).write(
            to: hooksLeaf.appendingPathComponent("cursor.hooks.workspaceId-test.log"),
            atomically: true,
            encoding: .utf8
        )

        let loader = UsageHistoryLoader(
            claudeDir: emptyClaude,
            codexDir: emptyCodex,
            geminiDir: emptyGemini,
            agyDir: nil,
            opencodeDBURL: nil,
            cursorLedgerURL: dir.appendingPathComponent("missing-cursor-acp-usage.jsonl"),
            cursorHooksLogsDir: hooksRoot,
            cacheURL: dir.appendingPathComponent("cache.json")
        )

        let snapshot = await loader.loadAll()

        let cursor = try XCTUnwrap(snapshot.byProvider[.cursor])
        XCTAssertEqual(cursor.allTime.totals.inputTokens, 250)
        XCTAssertEqual(cursor.allTime.totals.outputTokens, 40)
        XCTAssertEqual(cursor.allTime.totals.cacheReadTokens, 700)
        XCTAssertEqual(cursor.allTime.totals.cacheCreationTokens, 50)
        XCTAssertEqual(cursor.allTime.totals.totalTokens, 1_040)
        XCTAssertEqual((cursor.allTime.totals.costUSD as NSDecimalNumber).doubleValue, 0.000239, accuracy: 0.000001)
        let composer = try XCTUnwrap(snapshot.tokensByModel["cursor/composer-2.5"])
        XCTAssertEqual(composer.totalTokens, 1_040)
        XCTAssertEqual((composer.costUSD as NSDecimalNumber).doubleValue, 0.000239, accuracy: 0.000001)
        XCTAssertNil(snapshot.unpricedModelTokens["composer-2.5"])
        let windowedModelTotal = snapshot.byDayByModel
            .values
            .compactMap { $0["cursor/composer-2.5"] }
            .reduce(TokenTotals.zero, +)
            .totalTokens
        XCTAssertEqual(windowedModelTotal, 1_040)
    }

    func test_liveCursorHookLogsProduceNonZeroTokensWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["CLAWDMETER_PROBE_CURSOR_HOOKS"] == "1" else {
            throw XCTSkip("Set CLAWDMETER_PROBE_CURSOR_HOOKS=1 to parse local Cursor hook logs")
        }
        let logsDir = try XCTUnwrap(CursorHooksUsageParser.defaultLogsDir())
        guard FileManager.default.fileExists(atPath: logsDir.path) else {
            throw XCTSkip("No local Cursor hook logs directory at \(logsDir.path)")
        }

        let dir = try tempDir()
        let emptyClaude = dir.appendingPathComponent("claude", isDirectory: true)
        let emptyCodex = dir.appendingPathComponent("codex", isDirectory: true)
        let emptyGemini = dir.appendingPathComponent("gemini", isDirectory: true)
        for url in [emptyClaude, emptyCodex, emptyGemini] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        let loader = UsageHistoryLoader(
            claudeDir: emptyClaude,
            codexDir: emptyCodex,
            geminiDir: emptyGemini,
            agyDir: nil,
            opencodeDBURL: nil,
            cursorLedgerURL: dir.appendingPathComponent("missing-cursor-acp-usage.jsonl"),
            cursorHooksLogsDir: logsDir,
            cacheURL: dir.appendingPathComponent("cache.json")
        )

        let snapshot = await loader.loadAll()
        let totalTokens = snapshot.cursor.allTime.totals.totalTokens
        let totalCost = (snapshot.cursor.allTime.totals.costUSD as NSDecimalNumber).doubleValue
        let cursorModels = snapshot.tokensByModel
            .filter { $0.key.hasPrefix("cursor/") }
            .sorted { $0.value.totalTokens > $1.value.totalTokens }
            .map { "\($0.key)=\($0.value.totalTokens)/$\((($0.value.costUSD as NSDecimalNumber).doubleValue))" }
            .joined(separator: ", ")
        print("Cursor hook live tokens: \(totalTokens); cost: $\(totalCost); models: \(cursorModels)")

        XCTAssertGreaterThan(totalTokens, 0)
        XCTAssertGreaterThan(totalCost, 0)
        XCTAssertTrue(snapshot.tokensByModel.keys.contains { $0.hasPrefix("cursor/") })
    }

    private func fixtureLog(repoPath: String) -> String {
        """
        [2026-06-05T16:08:32.922Z] Hook step requested: sessionStart
        INPUT:
        {
          "conversation_id": "session-1",
          "generation_id": "",
          "model": "composer-2.5",
          "session_id": "session-1",
          "hook_event_name": "sessionStart",
          "workspace_roots": [
            "\(repoPath)"
          ],
          "transcript_path": null
        }

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

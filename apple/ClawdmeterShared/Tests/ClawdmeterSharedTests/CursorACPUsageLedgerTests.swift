import XCTest
@testable import ClawdmeterShared

final class CursorACPUsageLedgerTests: XCTestCase {
    private func tempDir(_ name: String = UUID().uuidString) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CursorACPUsageLedgerTests", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func test_appendAndParseFile_emitsCursorUsageRecord() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("cursor-acp-usage.jsonl")
        let sessionId = UUID()

        CursorACPUsageLedger.append(CursorACPUsageLedgerRecord(
            timestamp: Date(timeIntervalSince1970: 1_779_582_000),
            surface: .code,
            sessionId: sessionId,
            externalSessionId: "cursor-session-1",
            repo: "/tmp/repo",
            model: "gpt-5",
            inputTokens: 120,
            outputTokens: 80,
            totalTokens: 200,
            costUSD: Decimal(string: "0.42")
        ), url: url)

        let records = CursorACPUsageLedger.parseFile(at: url)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].provider, .cursor)
        XCTAssertEqual(records[0].repo, "/tmp/repo")
        XCTAssertEqual(records[0].model, "gpt-5")
        XCTAssertEqual(records[0].tokens.inputTokens, 120)
        XCTAssertEqual(records[0].tokens.outputTokens, 80)
        XCTAssertEqual(records[0].tokens.costUSD, Decimal(string: "0.42"))
        XCTAssertEqual(records[0].tokens.requestCount, 1)
    }

    func test_usageHistoryLoader_includesCursorLedgerRecords() async throws {
        let dir = try tempDir()
        let cursorURL = dir.appendingPathComponent("cursor-acp-usage.jsonl")
        let cacheURL = dir.appendingPathComponent("cache.json")
        let emptyClaude = dir.appendingPathComponent("claude", isDirectory: true)
        let emptyCodex = dir.appendingPathComponent("codex", isDirectory: true)
        let emptyGemini = dir.appendingPathComponent("gemini", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyClaude, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: emptyCodex, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: emptyGemini, withIntermediateDirectories: true)

        CursorACPUsageLedger.append(CursorACPUsageLedgerRecord(
            timestamp: Date(),
            surface: .chat,
            sessionId: UUID(),
            externalSessionId: nil,
            repo: nil,
            model: "cursor-fast",
            inputTokens: 40,
            outputTokens: 10,
            totalTokens: 50,
            costUSD: Decimal(string: "0.25")
        ), url: cursorURL)

        let loader = UsageHistoryLoader(
            claudeDir: emptyClaude,
            codexDir: emptyCodex,
            geminiDir: emptyGemini,
            agyDir: nil,
            opencodeDBURL: nil,
            cursorLedgerURL: cursorURL,
            cacheURL: cacheURL
        )
        let snapshot = await loader.loadAll()

        let cursor = try XCTUnwrap(snapshot.byProvider[.cursor])
        XCTAssertEqual(cursor.allTime.totals.inputTokens, 40)
        XCTAssertEqual(cursor.allTime.totals.outputTokens, 10)
        XCTAssertEqual(cursor.allTime.totals.costUSD, Decimal(string: "0.25"))
        XCTAssertEqual(cursor.allTime.totals.requestCount, 1)
        XCTAssertEqual(snapshot.tokensByModel["cursor/cursor-fast"]?.totalTokens, 50)
        XCTAssertEqual(snapshot.tokensByModel["cursor/cursor-fast"]?.costUSD, Decimal(string: "0.25"))
    }
}

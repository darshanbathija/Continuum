import XCTest
@testable import ClawdmeterShared
#if os(macOS)
import SQLite3
#endif

final class CursorAgentTranscriptParserTests: XCTestCase {
    private func tempDir(_ name: String = UUID().uuidString) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CursorAgentTranscriptParserTests", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func test_parseAgentTranscript_emitsEstimatedCursorRecords() throws {
        let dir = try tempDir()
        let repo = dir.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        let file = dir.appendingPathComponent("session-a.jsonl")
        try transcript(repoPath: repo.path).write(to: file, atomically: true, encoding: .utf8)

        let records = try CursorAgentTranscriptParser.parse(file: file)

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.map(\.provider), [.cursor])
        XCTAssertEqual(records[0].repo, repo.path)
        XCTAssertEqual(records[0].model, "composer-2.5-fast")
        XCTAssertGreaterThan(records[0].tokens.inputTokens, 0)
        XCTAssertGreaterThan(records[0].tokens.outputTokens, 0)
        XCTAssertNotNil(records[0].dedupKey)
    }

    func test_parseAgentTranscript_estimatesCumulativeContextPerAssistantRequest() throws {
        let dir = try tempDir()
        let file = dir.appendingPathComponent("session.jsonl")
        let firstPrompt = String(repeating: "first prompt ", count: 80)
        let firstReply = String(repeating: "first reply ", count: 80)
        let secondPrompt = String(repeating: "second prompt ", count: 80)
        let secondReply = String(repeating: "second reply ", count: 80)
        let json = """
        {"role":"user","message":{"content":[{"type":"text","text":\(jsonString(firstPrompt))}]}}
        {"role":"assistant","message":{"content":[{"type":"text","text":\(jsonString(firstReply))}]}}
        {"role":"user","message":{"content":[{"type":"text","text":\(jsonString(secondPrompt))}]}}
        {"role":"assistant","message":{"content":[{"type":"text","text":\(jsonString(secondReply))}]}}
        """
        try json.write(to: file, atomically: true, encoding: .utf8)

        let records = try CursorAgentTranscriptParser.parse(file: file)

        XCTAssertEqual(records.count, 2)
        XCTAssertGreaterThan(records[1].tokens.inputTokens, records[0].tokens.inputTokens)
        XCTAssertGreaterThan(records[1].tokens.totalTokens, records[1].tokens.outputTokens)
    }

    func test_parseAgentTranscript_doesNotTreatTaskTargetModelAsParentModel() throws {
        let dir = try tempDir()
        let file = dir.appendingPathComponent("parent.jsonl")
        let json = """
        {"role":"user","message":{"content":[{"type":"text","text":"Launch an Opus worker."}]}}
        {"role":"assistant","message":{"content":[{"type":"text","text":"Launching worker."},{"type":"tool_use","name":"Task","input":{"description":"Review","model":"claude-opus-4-8-thinking-high","prompt":"Review deeply."}}]}}
        """
        try json.write(to: file, atomically: true, encoding: .utf8)

        let records = try CursorAgentTranscriptParser.parse(file: file)

        XCTAssertEqual(records.map(\.model), ["composer-2.5-fast"])
    }

    func test_usageHistoryLoader_includesCursorAgentTranscriptsAndDedupesDuplicateCopies() async throws {
        let dir = try tempDir()
        let emptyClaude = dir.appendingPathComponent("claude", isDirectory: true)
        let emptyCodex = dir.appendingPathComponent("codex", isDirectory: true)
        let emptyGemini = dir.appendingPathComponent("gemini", isDirectory: true)
        let cursorRoot = dir.appendingPathComponent("cursor-projects", isDirectory: true)
        let repo = dir.appendingPathComponent("repo", isDirectory: true)
        for url in [emptyClaude, emptyCodex, emptyGemini] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )

        let sessionID = "f3306f0b-ec18-44d8-934a-04d0fb40e0f1"
        let first = cursorRoot
            .appendingPathComponent("empty-window", isDirectory: true)
            .appendingPathComponent("agent-transcripts", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
            .appendingPathComponent("\(sessionID).jsonl")
        let duplicate = cursorRoot
            .appendingPathComponent("project", isDirectory: true)
            .appendingPathComponent("agent-transcripts", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
            .appendingPathComponent("\(sessionID).jsonl")
        try FileManager.default.createDirectory(at: first.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: duplicate.deletingLastPathComponent(), withIntermediateDirectories: true)
        try transcript(repoPath: repo.path).write(to: first, atomically: true, encoding: .utf8)
        try transcript(repoPath: repo.path).write(to: duplicate, atomically: true, encoding: .utf8)

        let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
        let newDate = Date(timeIntervalSince1970: 1_700_000_060)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: first.path)
        try FileManager.default.setAttributes([.modificationDate: newDate], ofItemAtPath: duplicate.path)

        let expectedTokens = try CursorAgentTranscriptParser.parse(file: duplicate)
            .map(\.tokens)
            .reduce(TokenTotals.zero, +)

        let loader = UsageHistoryLoader(
            claudeDir: emptyClaude,
            codexDir: emptyCodex,
            geminiDir: emptyGemini,
            agyDir: nil,
            opencodeDBURL: nil,
            cursorLedgerURL: dir.appendingPathComponent("missing-cursor-acp-usage.jsonl"),
            cursorHooksLogsDir: nil,
            cursorAgentTranscriptRoot: cursorRoot,
            cacheURL: dir.appendingPathComponent("cache.json")
        )

        let snapshot = await loader.loadAll()

        let cursor = try XCTUnwrap(snapshot.byProvider[.cursor])
        XCTAssertEqual(cursor.allTime.totals.totalTokens, expectedTokens.totalTokens)
        XCTAssertGreaterThan((cursor.allTime.totals.costUSD as NSDecimalNumber).doubleValue, 0)
        let modelTotals = try XCTUnwrap(snapshot.tokensByModel["cursor/composer-2.5-fast"])
        XCTAssertEqual(modelTotals.totalTokens, expectedTokens.totalTokens)
        XCTAssertGreaterThan((modelTotals.costUSD as NSDecimalNumber).doubleValue, 0)
    }

    func test_subagentTranscript_inheritsModelFromParentTaskPrompt() throws {
        let dir = try tempDir()
        let parent = dir.appendingPathComponent("parent.jsonl")
        let child = dir.appendingPathComponent("child.jsonl")
        let taskPrompt = """
        Audit the shared analytics package for Cursor cost bugs.
        Return concrete findings with file references.
        """
        let parentJSON = """
        {"role":"assistant","message":{"content":[{"type":"tool_use","name":"Task","input":{"description":"Review Cursor analytics","model":"claude-opus-4-8-thinking-high","prompt":\(jsonString(taskPrompt))}}]}}
        """
        let childJSON = """
        {"role":"user","message":{"content":[{"type":"text","text":"<timestamp>Friday, Jun 5, 2026, 11:10 PM (UTC+7)</timestamp>\\n<user_query>\\nAudit the shared analytics package for Cursor cost bugs.\\nReturn concrete findings with file references.\\n</user_query>"}]}}
        {"role":"assistant","message":{"content":[{"type":"text","text":"Found a Cursor analytics undercount."}]}}
        """
        try parentJSON.write(to: parent, atomically: true, encoding: .utf8)
        try childJSON.write(to: child, atomically: true, encoding: .utf8)

        let hints = try CursorAgentTranscriptParser.taskModelHints(file: parent)
        let records = try CursorAgentTranscriptParser.parse(file: child, modelHints: hints)

        XCTAssertEqual(Set(records.map(\.model)), ["claude-opus-4-8-thinking-high"])
    }

    #if os(macOS)
    func test_parseAgentKVBlob_emitsEstimatedCursorContextRecord() throws {
        let dir = try tempDir()
        let repo = dir.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        let data = try agentKVBlob(
            role: "user",
            content: """
            <user_info>
            Workspace Path: \(repo.path)
            Today's date: Saturday Jun 6, 2026
            </user_info>
            Large persisted Cursor context.
            """,
            modelName: nil
        )

        let record = try XCTUnwrap(CursorAgentKVUsageParser.parseBlob(
            key: "agentKv:blob:test",
            data: data,
            fallbackTimestamp: Date(timeIntervalSince1970: 1)
        ))

        XCTAssertEqual(record.provider, .cursor)
        XCTAssertEqual(record.repo, repo.path)
        XCTAssertEqual(record.model, "composer-2.5-fast")
        XCTAssertGreaterThan(record.tokens.inputTokens, 0)
        XCTAssertEqual(record.tokens.outputTokens, 0)
        XCTAssertNotNil(record.dedupKey)
        XCTAssertEqual(Calendar.current.component(.day, from: record.timestamp), 6)
    }

    func test_parseAgentKVBlob_countsToolResultsAsInputContext() throws {
        let data = try agentKVBlob(
            role: "tool",
            content: [[
                "type": "tool-result",
                "toolName": "Read",
                "result": String(repeating: "tool context ", count: 200),
            ]],
            modelName: "composer-2.5-fast"
        )

        let record = try XCTUnwrap(CursorAgentKVUsageParser.parseBlob(
            key: "agentKv:blob:tool",
            data: data,
            fallbackTimestamp: Date(timeIntervalSince1970: 1)
        ))

        XCTAssertGreaterThan(record.tokens.inputTokens, 0)
        XCTAssertEqual(record.tokens.outputTokens, 0)
        XCTAssertEqual(record.model, "composer-2.5-fast")
    }

    func test_parseAgentKVBlob_readsNestedCursorProviderModel() throws {
        let object: [String: Any] = [
            "role": "assistant",
            "content": [[
                "type": "reasoning",
                "text": String(repeating: "opus reasoning ", count: 100),
                "providerOptions": [
                    "cursor": [
                        "modelName": "claude-opus-4-8-thinking-high",
                    ],
                ],
            ]],
        ]
        let data = try JSONSerialization.data(withJSONObject: object)

        let record = try XCTUnwrap(CursorAgentKVUsageParser.parseBlob(
            key: "agentKv:blob:nested-assistant",
            data: data,
            fallbackTimestamp: Date(timeIntervalSince1970: 1)
        ))

        XCTAssertEqual(record.model, "claude-opus-4-8-thinking-high")
        XCTAssertEqual(record.tokens.inputTokens, 0)
        XCTAssertGreaterThan(record.tokens.outputTokens, 0)
    }

    func test_parseAgentKVDatabase_attributesBedrockToolResultsToObservedClaudeModel() throws {
        let dir = try tempDir()
        let db = dir.appendingPathComponent("state.vscdb")
        let assistantObject: [String: Any] = [
            "role": "assistant",
            "content": [[
                "type": "reasoning",
                "text": "thinking",
                "providerOptions": [
                    "cursor": [
                        "modelName": "claude-opus-4-8-thinking-high",
                    ],
                ],
            ]],
        ]
        let toolObject: [String: Any] = [
            "role": "tool",
            "content": [[
                "type": "tool-result",
                "toolCallId": "toolu_bdrk_01abc",
                "toolName": "Read",
                "result": String(repeating: "claude tool context ", count: 100),
            ]],
            "providerOptions": [
                "cursor": [
                    "highLevelToolCallResult": ["isError": false],
                ],
            ],
        ]
        try writeCursorAgentKVDatabase(db, rows: [
            ("agentKv:blob:assistant", try JSONSerialization.data(withJSONObject: assistantObject)),
            ("agentKv:blob:tool", try JSONSerialization.data(withJSONObject: toolObject)),
        ])

        let records = CursorAgentKVUsageParser.parse(databaseURL: db)
        let tool = try XCTUnwrap(records.first { $0.dedupKey?.contains("agentKv:blob:tool") == true })

        XCTAssertEqual(tool.model, "claude-opus-4-8-thinking-high")
        XCTAssertGreaterThan(tool.tokens.inputTokens, 0)
        XCTAssertEqual(tool.tokens.outputTokens, 0)
    }

    func test_usageHistoryLoader_includesCursorAgentKVDatabase() async throws {
        let dir = try tempDir()
        let emptyClaude = dir.appendingPathComponent("claude", isDirectory: true)
        let emptyCodex = dir.appendingPathComponent("codex", isDirectory: true)
        let emptyGemini = dir.appendingPathComponent("gemini", isDirectory: true)
        let repo = dir.appendingPathComponent("repo", isDirectory: true)
        for url in [emptyClaude, emptyCodex, emptyGemini] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )

        let db = dir.appendingPathComponent("state.vscdb")
        try writeCursorAgentKVDatabase(db, rows: [
            (
                "agentKv:blob:user",
                try agentKVBlob(
                    role: "user",
                    content: """
                    <user_info>
                    Workspace Path: \(repo.path)
                    Today's date: Saturday Jun 6, 2026
                    </user_info>
                    \(String(repeating: "input context ", count: 200))
                    """,
                    modelName: "composer-2.5-fast"
                )
            ),
            (
                "agentKv:blob:assistant",
                try agentKVBlob(
                    role: "assistant",
                    content: String(repeating: "assistant result ", count: 100),
                    modelName: "claude-opus-4-8-thinking-high"
                )
            ),
        ])

        let loader = UsageHistoryLoader(
            claudeDir: emptyClaude,
            codexDir: emptyCodex,
            geminiDir: emptyGemini,
            agyDir: nil,
            opencodeDBURL: nil,
            cursorLedgerURL: dir.appendingPathComponent("missing-cursor-acp-usage.jsonl"),
            cursorHooksLogsDir: nil,
            cursorAgentTranscriptRoot: nil,
            cursorAgentKVDBURL: db,
            cacheURL: dir.appendingPathComponent("cache.json")
        )

        let snapshot = await loader.loadAll()

        let cursor = try XCTUnwrap(snapshot.byProvider[.cursor])
        XCTAssertGreaterThan(cursor.allTime.totals.totalTokens, 0)
        XCTAssertGreaterThan((cursor.allTime.totals.costUSD as NSDecimalNumber).doubleValue, 0)
        XCTAssertNotNil(snapshot.tokensByModel["cursor/composer-2.5-fast"])
        let opus = try XCTUnwrap(snapshot.tokensByModel["cursor/claude-opus-4-8-thinking-high"])
        XCTAssertGreaterThan((opus.costUSD as NSDecimalNumber).doubleValue, 0)
    }
    #endif

    func test_liveCursorAgentTranscriptsProduceNonZeroTokensWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["CLAWDMETER_PROBE_CURSOR_TRANSCRIPTS"] == "1" else {
            throw XCTSkip("Set CLAWDMETER_PROBE_CURSOR_TRANSCRIPTS=1 to parse local Cursor agent transcripts")
        }
        let cursorRoot = try XCTUnwrap(CursorAgentTranscriptParser.defaultProjectsDir())
        guard FileManager.default.fileExists(atPath: cursorRoot.path) else {
            throw XCTSkip("No local Cursor projects directory at \(cursorRoot.path)")
        }
        #if os(macOS)
        let cursorAgentKVDBURL = CursorAgentKVUsageParser.defaultStateDatabaseURL()
        #else
        let cursorAgentKVDBURL: URL? = nil
        #endif

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
            cursorHooksLogsDir: nil,
            cursorAgentTranscriptRoot: cursorRoot,
            cursorAgentKVDBURL: cursorAgentKVDBURL,
            cacheURL: dir.appendingPathComponent("cache.json")
        )

        let snapshot = await loader.loadAll()
        let cursor = try XCTUnwrap(snapshot.byProvider[.cursor])
        XCTAssertGreaterThan(cursor.allTime.totals.totalTokens, 0)
        XCTAssertGreaterThan((cursor.allTime.totals.costUSD as NSDecimalNumber).doubleValue, 0)
    }

    private func transcript(repoPath: String) -> String {
        """
        {"role":"user","message":{"content":[{"type":"text","text":"<user_query>\\nAudit the repo thoroughly.\\nWorkspace Path: \(repoPath)\\n</user_query>"}]}}
        {"role":"assistant","message":{"content":[{"type":"text","text":"Launching parallel Cursor subagents and collecting results."},{"type":"tool_use","name":"Task","input":{"description":"Review analytics","model":"composer-2.5-fast","prompt":"Review Cursor usage analytics, inspect token and cost rollups, and return concrete findings for \(repoPath)."}}]}}
        """
    }

    private func jsonString(_ value: String) -> String {
        let data = try! JSONEncoder().encode(value)
        return String(data: data, encoding: .utf8)!
    }

    #if os(macOS)
    private func agentKVBlob(role: String, content: Any, modelName: String?) throws -> Data {
        var cursorOptions: [String: Any] = [
            "requestContextCompleteness": [
                "rules": true,
                "env": true,
                "repositoryInfo": true,
            ],
        ]
        if let modelName {
            cursorOptions["modelName"] = modelName
        }
        let object: [String: Any] = [
            "role": role,
            "content": content,
            "providerOptions": [
                "cursor": cursorOptions,
            ],
        ]
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func writeCursorAgentKVDatabase(_ url: URL, rows: [(String, Data)]) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil), SQLITE_OK)
        guard let db else { return }
        defer { sqlite3_close_v2(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE cursorDiskKV (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);", nil, nil, nil), SQLITE_OK)

        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "INSERT INTO cursorDiskKV (key, value) VALUES (?, ?);", -1, &stmt, nil), SQLITE_OK)
        guard let stmt else { return }
        defer { sqlite3_finalize(stmt) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (key, data) in rows {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            sqlite3_bind_text(stmt, 1, key, -1, transient)
            _ = data.withUnsafeBytes { raw in
                sqlite3_bind_blob(stmt, 2, raw.baseAddress, Int32(data.count), transient)
            }
            XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
        }
    }
    #endif
}

import XCTest
@testable import ClawdmeterShared

/// Multi-account Phase 7: `UsageHistoryLoader` ingesting secondary
/// accounts' JSONL trees (`$CLAUDE_CONFIG_DIR/projects`) into the
/// AGGREGATE totals.
final class MultiAccountAnalyticsTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("MultiAccountAnalyticsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    /// One usage-bearing assistant turn. Distinct message/request ids per
    /// account so the `messageId:requestId` dedup can't collapse them.
    private func writeClaudeTree(
        root: URL,
        idSuffix: String,
        inputTokens: Int,
        outputTokens: Int
    ) throws {
        let sessionDir = root.appendingPathComponent("-Users-x-r1", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let line = """
        {"timestamp":"2026-05-15T10:00:00Z","requestId":"req_\(idSuffix)","cwd":"/Users/x/r1","message":{"id":"msg_\(idSuffix)","role":"assistant","model":"claude-sonnet-4-5","content":[{"type":"text","text":"x"}],"usage":{"input_tokens":\(inputTokens),"output_tokens":\(outputTokens),"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
        """
        try line.write(
            to: sessionDir.appendingPathComponent("session.jsonl"),
            atomically: true, encoding: .utf8
        )
    }

    private func makeLoader(
        primary: URL,
        additional: @escaping @Sendable () -> [URL],
        cacheName: String
    ) throws -> UsageHistoryLoader {
        let codexDir = tmp.appendingPathComponent("codex", isDirectory: true)
        let geminiDir = tmp.appendingPathComponent("gemini", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: geminiDir, withIntermediateDirectories: true)
        return UsageHistoryLoader(
            claudeDir: primary,
            codexDir: codexDir,
            geminiDir: geminiDir,
            cacheURL: tmp.appendingPathComponent(cacheName),
            additionalClaudeDirs: additional
        )
    }

    func testSecondaryRootsJoinAggregateTotals() async throws {
        let primary = tmp.appendingPathComponent("primary/projects", isDirectory: true)
        let work = tmp.appendingPathComponent("instances/claude/work/projects", isDirectory: true)
        try writeClaudeTree(root: primary, idSuffix: "primary", inputTokens: 1000, outputTokens: 200)
        try writeClaudeTree(root: work, idSuffix: "work", inputTokens: 500, outputTokens: 80)

        let loader = try makeLoader(primary: primary, additional: { [work] }, cacheName: "cache-a.json")
        let snapshot = await loader.loadAll()

        let claude = snapshot.byProvider[.claude]
        XCTAssertEqual(claude?.allTime.totals.inputTokens, 1500, "both accounts' trees must sum")
        XCTAssertEqual(claude?.allTime.totals.outputTokens, 280)
    }

    func testMissingSecondaryRootSkipsSilently() async throws {
        let primary = tmp.appendingPathComponent("primary/projects", isDirectory: true)
        try writeClaudeTree(root: primary, idSuffix: "primary", inputTokens: 1000, outputTokens: 200)
        let ghost = tmp.appendingPathComponent("instances/claude/ghost/projects", isDirectory: true)

        let loader = try makeLoader(primary: primary, additional: { [ghost] }, cacheName: "cache-b.json")
        let snapshot = await loader.loadAll()

        XCTAssertEqual(snapshot.byProvider[.claude]?.allTime.totals.inputTokens, 1000)
    }

    func testAccountAddedBetweenRefreshesAppearsWithoutRebuild() async throws {
        let primary = tmp.appendingPathComponent("primary/projects", isDirectory: true)
        let work = tmp.appendingPathComponent("instances/claude/work/projects", isDirectory: true)
        try writeClaudeTree(root: primary, idSuffix: "primary", inputTokens: 1000, outputTokens: 200)

        // The roots closure reads mutable state — same shape as the
        // production closure reading ProviderInstanceStore per refresh.
        let extraRoots = ExtraRootsBox()
        let loader = try makeLoader(
            primary: primary,
            additional: { extraRoots.roots },
            cacheName: "cache-c.json"
        )

        let before = await loader.loadAll()
        XCTAssertEqual(before.byProvider[.claude]?.allTime.totals.inputTokens, 1000)

        try writeClaudeTree(root: work, idSuffix: "work", inputTokens: 500, outputTokens: 80)
        extraRoots.roots = [work]

        let after = await loader.refresh()
        XCTAssertEqual(after.byProvider[.claude]?.allTime.totals.inputTokens, 1500)
    }
}

/// NSLock-guarded mutable root list for the closure-reads-live-state test.
private final class ExtraRootsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _roots: [URL] = []
    var roots: [URL] {
        get { lock.lock(); defer { lock.unlock() }; return _roots }
        set { lock.lock(); defer { lock.unlock() }; _roots = newValue }
    }
}

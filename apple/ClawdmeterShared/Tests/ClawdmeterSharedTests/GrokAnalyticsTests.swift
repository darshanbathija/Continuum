import XCTest
@testable import ClawdmeterShared

final class GrokAnalyticsTests: XCTestCase {
    func test_grokProviderIdentityIsFirstClass() {
        XCTAssertTrue(UsageRecord.Provider.allCases.contains(.grok))
        XCTAssertEqual(AgentKindUI.displayName(for: UsageRecord.Provider.grok), "Grok")
        XCTAssertEqual(AgentKindUI.assetName(for: UsageRecord.Provider.grok), "GrokLogo")
        XCTAssertTrue(UsageHistoryStore.ProviderFilter.grok.includes(.grok))
        XCTAssertTrue(ProviderEnablement.allProviderIds.contains("grok"))

        #if canImport(SwiftUI)
        XCTAssertTrue(TahoeProvider.allCases.contains(.grok))
        XCTAssertEqual(TahoeProvider.grok.displayName, "Grok")
        XCTAssertEqual(TahoeProvider.grok.logoAssetName, "tahoe-grok-mark")
        XCTAssertEqual(AgentKind.grok.tahoeProvider, .grok)
        #endif
    }

#if !os(watchOS) && canImport(SwiftUI)
    @available(macOS 13, iOS 16, *)
    func test_totalsGridShowsUnpricedGrokTokensBeforeRequestCount() {
        let unpricedGrok = TokenTotals(inputTokens: 120, outputTokens: 45, requestCount: 1)
        XCTAssertEqual(
            AnalyticsTotalsGrid.cellDisplay(for: unpricedGrok),
            .tokens("165 tok")
        )

        let requestOnly = TokenTotals(requestCount: 3)
        XCTAssertEqual(
            AnalyticsTotalsGrid.cellDisplay(for: requestOnly),
            .requests("3 reqs")
        )
    }
#endif

    func test_grokLedgerPreservesExplicitTotalTokenRemainder() throws {
        let entry = GrokUsageLedger.Entry(
            timestamp: Date(timeIntervalSince1970: 1_779_000_000),
            sessionId: "grok-session-total",
            repo: nil,
            model: "grok-build",
            inputTokens: 10,
            outputTokens: 5,
            totalTokens: 25,
            dedupKey: "grok:test:total"
        )

        let record = try XCTUnwrap(entry.usageRecord())
        XCTAssertEqual(record.provider, .grok)
        XCTAssertEqual(record.tokens.inputTokens, 10)
        XCTAssertEqual(record.tokens.outputTokens, 5)
        XCTAssertEqual(record.tokens.reasoningTokens, 10)
        XCTAssertEqual(record.tokens.totalTokens, 25)
        XCTAssertEqual(record.tokens.requestCount, 1)
    }

    func test_grokCLISignalsParseIntoUsageRecord() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-cli-signals-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let repo = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )

        let encodedRepo = try XCTUnwrap(repo.path.addingPercentEncoding(withAllowedCharacters: .alphanumerics))
        let signalsURL = root
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(encodedRepo, isDirectory: true)
            .appendingPathComponent("session-1", isDirectory: true)
            .appendingPathComponent("signals.json")
        try FileManager.default.createDirectory(
            at: signalsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("""
        {
          "turnCount": 2,
          "totalTokensBeforeCompaction": 1000,
          "contextTokensUsed": 42000,
          "contextWindowTokens": 512000,
          "primaryModelId": "grok-build"
        }
        """.utf8).write(to: signalsURL)

        let mtime = Date(timeIntervalSince1970: 1_779_111_000)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: signalsURL.path)

        let record = try XCTUnwrap(GrokCLIUsageParser.parseSignals(at: signalsURL))
        XCTAssertEqual(record.provider, .grok)
        XCTAssertEqual(record.model, "grok-build")
        XCTAssertEqual(record.repo, repo.path)
        XCTAssertEqual(record.dedupKey, "grok-cli:session-1:signals")
        XCTAssertEqual(record.tokens.inputTokens, 43_000)
        XCTAssertEqual(record.tokens.totalTokens, 43_000)
        XCTAssertEqual(record.tokens.requestCount, 2)
        XCTAssertEqual(record.timestamp.timeIntervalSince1970, mtime.timeIntervalSince1970, accuracy: 0.001)

        let limit = try XCTUnwrap(GrokCLIUsageParser.parseContextLimit(at: signalsURL))
        XCTAssertEqual(limit.usedTokens, 42_000)
        XCTAssertEqual(limit.limitTokens, 512_000)
        XCTAssertEqual(limit.roundedPercent, 8)
        XCTAssertEqual(limit.model, "grok-build")
    }

    func test_grokCLISignalsSplitBuildAndComposerModelsWithoutDoubleCountingProvider() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-cli-multi-model-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let repo = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )

        let encodedRepo = try XCTUnwrap(repo.path.addingPercentEncoding(withAllowedCharacters: .alphanumerics))
        let signalsURL = root
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(encodedRepo, isDirectory: true)
            .appendingPathComponent("session-multi", isDirectory: true)
            .appendingPathComponent("signals.json")
        try FileManager.default.createDirectory(
            at: signalsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("""
        {
          "turnCount": 3,
          "contextTokensUsed": 1001,
          "contextWindowTokens": 512000,
          "primaryModelId": "grok-build",
          "modelsUsed": ["grok-build", "grok-composer-2.5-fast"]
        }
        """.utf8).write(to: signalsURL)

        let records = GrokCLIUsageParser.parseUsageRecords(at: signalsURL)
        XCTAssertEqual(records.map(\.model), ["grok-build", "grok-composer-2.5-fast"])
        XCTAssertEqual(records.map(\.tokens.totalTokens).reduce(0, +), 1001)
        XCTAssertEqual(records.map(\.tokens.requestCount).reduce(0, +), 3)
        XCTAssertEqual(records.first(where: { $0.model == "grok-build" })?.tokens.totalTokens, 501)
        XCTAssertEqual(records.first(where: { $0.model == "grok-composer-2.5-fast" })?.tokens.totalTokens, 500)
    }

    func test_grokLedgerLoadsIntoProviderModelDayAndRepoTotals() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-analytics-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let ledgerURL = root.appendingPathComponent("grok-usage.jsonl")
        let cacheURL = root.appendingPathComponent("analytics-cache.json")
        let repo = root.appendingPathComponent("repo", isDirectory: true).path
        let now = Date()
        let day = Calendar.current.startOfDay(for: now)

        try GrokUsageLedger.append(
            GrokUsageLedger.Entry(
                timestamp: now,
                sessionId: "grok-session-1",
                repo: repo,
                model: "grok-build",
                inputTokens: 120,
                outputTokens: 45,
                totalTokens: 165,
                dedupKey: "grok:test:1"
            ),
            to: ledgerURL
        )

        let loader = UsageHistoryLoader(
            claudeDir: root.appendingPathComponent("claude", isDirectory: true),
            codexDir: root.appendingPathComponent("codex", isDirectory: true),
            geminiDir: root.appendingPathComponent("gemini", isDirectory: true),
            agyDir: nil,
            opencodeDBURL: nil,
            grokLedgerURL: ledgerURL,
            cacheURL: cacheURL
        )
        let snapshot = await loader.loadAll()

        let grok = try XCTUnwrap(snapshot.byProvider[.grok])
        XCTAssertEqual(grok.today.totals.inputTokens, 120)
        XCTAssertEqual(grok.today.totals.outputTokens, 45)
        XCTAssertEqual(grok.today.totals.totalTokens, 165)
        XCTAssertEqual(grok.today.byRepo.first(where: { $0.repo == repo })?.totals.totalTokens, 165)
        XCTAssertEqual(snapshot.tokensByModel["grok-build"]?.totalTokens, 165)
        XCTAssertEqual(snapshot.byDayByModel[day]?["grok-build"]?.totalTokens, 165)
        XCTAssertEqual(snapshot.unpricedModelTokens["grok-build"]?.totalTokens, 165)
    }

    func test_grokCLISignalsLoadIntoProviderModelDayAndRepoTotals() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-cli-analytics-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let repoURL = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(
            at: repoURL.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )

        let sessionsRoot = root.appendingPathComponent("grok-sessions", isDirectory: true)
        let encodedRepo = try XCTUnwrap(repoURL.path.addingPercentEncoding(withAllowedCharacters: .alphanumerics))
        let signalsURL = sessionsRoot
            .appendingPathComponent(encodedRepo, isDirectory: true)
            .appendingPathComponent("session-analytics", isDirectory: true)
            .appendingPathComponent("signals.json")
        try FileManager.default.createDirectory(
            at: signalsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("""
        {
          "turnCount": 3,
          "contextTokensUsed": 26000,
          "contextWindowTokens": 200000,
          "primaryModelId": "grok-composer-2.5-fast",
          "modelsUsed": ["grok-composer-2.5-fast"]
        }
        """.utf8).write(to: signalsURL)

        let now = Date()
        let day = Calendar.current.startOfDay(for: now)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: signalsURL.path)

        let loader = UsageHistoryLoader(
            claudeDir: root.appendingPathComponent("claude", isDirectory: true),
            codexDir: root.appendingPathComponent("codex", isDirectory: true),
            geminiDir: root.appendingPathComponent("gemini", isDirectory: true),
            agyDir: nil,
            opencodeDBURL: nil,
            grokLedgerURL: nil,
            grokSessionsDir: sessionsRoot,
            cacheURL: root.appendingPathComponent("analytics-cache.json")
        )
        let snapshot = await loader.loadAll()

        let grok = try XCTUnwrap(snapshot.byProvider[.grok])
        XCTAssertEqual(grok.today.totals.inputTokens, 26_000)
        XCTAssertEqual(grok.today.totals.totalTokens, 26_000)
        XCTAssertEqual(grok.today.totals.requestCount, 3)
        XCTAssertEqual(grok.today.byRepo.first(where: { $0.repo == repoURL.path })?.totals.totalTokens, 26_000)
        XCTAssertEqual(snapshot.tokensByModel["grok-composer-2.5-fast"]?.totalTokens, 26_000)
        XCTAssertEqual(snapshot.byDayByModel[day]?["grok-composer-2.5-fast"]?.totalTokens, 26_000)
        XCTAssertEqual(snapshot.unpricedModelTokens["grok-composer-2.5-fast"]?.totalTokens, 26_000)
        XCTAssertEqual(snapshot.grokContextLimit?.model, "grok-composer-2.5-fast")
        XCTAssertEqual(snapshot.grokContextLimit?.usedTokens, 26_000)
        XCTAssertEqual(snapshot.grokContextLimit?.limitTokens, 200_000)
        XCTAssertEqual(snapshot.grokContextLimit?.roundedPercent, 13)
    }
}

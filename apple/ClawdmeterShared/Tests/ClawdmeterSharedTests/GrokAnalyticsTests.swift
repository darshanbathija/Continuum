import XCTest
@testable import ClawdmeterShared

final class GrokAnalyticsTests: XCTestCase {
    func test_grokProviderIdentityIsFirstClass() {
        XCTAssertTrue(TahoeProvider.allCases.contains(.grok))
        XCTAssertEqual(TahoeProvider.grok.displayName, "Grok")
        XCTAssertEqual(TahoeProvider.grok.logoAssetName, "tahoe-grok-mark")
        XCTAssertTrue(UsageRecord.Provider.allCases.contains(.grok))
        XCTAssertEqual(AgentKind.grok.tahoeProvider, .grok)
        XCTAssertEqual(AgentKindUI.displayName(for: UsageRecord.Provider.grok), "Grok")
        XCTAssertEqual(AgentKindUI.assetName(for: UsageRecord.Provider.grok), "GrokLogo")
        XCTAssertTrue(UsageHistoryStore.ProviderFilter.grok.includes(.grok))
        XCTAssertTrue(ProviderEnablement.allProviderIds.contains("grok"))
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
}

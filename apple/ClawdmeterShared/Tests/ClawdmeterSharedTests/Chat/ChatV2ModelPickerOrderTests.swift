import XCTest
@testable import ClawdmeterShared

final class ChatV2ModelPickerOrderTests: XCTestCase {
    func test_sortModelPickerChoices_usesDefaultOrderWhenUsageIsAbsent() {
        let choices: [ProviderChoice] = [
            .builtin(.grok),
            .builtin(.antigravity),
            .builtin(.openrouter),
            .builtin(.cursor),
            .builtin(.chatgpt),
            .builtin(.claude),
        ]

        let sorted = ChatV2Store.sortModelPickerChoices(
            choices,
            usageSnapshot: nil,
            catalog: .bundled
        )

        XCTAssertEqual(
            sorted.compactMap(\.chatVendor),
            [.claude, .chatgpt, .cursor, .openrouter, .grok, .antigravity]
        )
    }

    func test_sortModelPickerChoices_prefersHigherPast30dUsage() {
        let choices: [ProviderChoice] = [
            .builtin(.claude),
            .builtin(.chatgpt),
            .builtin(.cursor),
        ]
        let heavyCodex = TokenTotals(inputTokens: 0, outputTokens: 9_000, requestCount: 1)
        let lightClaude = TokenTotals(inputTokens: 0, outputTokens: 100, requestCount: 1)
        let mediumCursor = TokenTotals(inputTokens: 0, outputTokens: 500, requestCount: 1)
        let snapshot = UsageHistorySnapshot(
            byProvider: [
                .claude: providerTotals(past30d: lightClaude),
                .codex: providerTotals(past30d: heavyCodex),
                .cursor: providerTotals(past30d: mediumCursor),
            ],
            computedAt: Date(),
            sequenceNumber: 1,
            sessionCount: 1,
            unpricedModelTokens: [:],
            tokensByModel: [:],
            byDayByModel: [:]
        )

        let sorted = ChatV2Store.sortModelPickerChoices(
            choices,
            usageSnapshot: snapshot,
            catalog: .bundled
        )

        XCTAssertEqual(sorted.compactMap(\.chatVendor), [.chatgpt, .cursor, .claude])
    }

    private func providerTotals(past30d: TokenTotals) -> ProviderTotals {
        let window = WindowTotals(totals: past30d, byRepo: [], restCount: 0)
        return ProviderTotals(
            today: .empty,
            past7d: .empty,
            past30d: window,
            past90d: window,
            allTime: window,
            byDay: [:]
        )
    }
}

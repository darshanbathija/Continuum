import XCTest
@testable import ClawdmeterShared

/// Parity tests for the F1e `AntigravityAdapter`. Covers both code paths:
///   - `.db` (Antigravity 2.0.6+ plaintext step_payload) →
///     `AntigravityDBUsage` rollup
///   - `.pb` (legacy encrypted archive) → `UsageRecord` (often
///     byte-÷-4 estimated)
///
/// Plan: F1e (Phase 1; D23) — last F1 adapter — see
/// `.claude/plans/study-this-codebase-crystalline-shore.md`
final class AntigravityAdapterTests: XCTestCase {

    private let timestamp = Date(timeIntervalSince1970: 1_715_000_000)

    // MARK: - .db path

#if os(macOS) || os(iOS)
    func test_translate_dbUsage_emitsAssistantMessageCompleted() {
        let usage = AntigravityDBUsage(
            inputTokens: 1500,
            outputTokens: 320,
            cachedTokens: 4200,
            reasoningTokens: 100,
            toolUseTokens: 0,
            recordCount: 3
        )
        let events = AntigravityAdapter.translate(
            dbUsage: usage,
            conversationUUID: "uuid-1",
            timestamp: timestamp,
            modelName: "gemini-3.1-pro",
            cwd: "/Users/x/myrepo",
            sessionId: "session-1",
            sequenceNumber: 0
        )
        XCTAssertEqual(events.count, 1)
        let event = events[0]
        XCTAssertEqual(event.providerKind, .gemini)
        XCTAssertEqual(event.id, "antigravity-uuid-1-0")

        guard case .assistantMessageCompleted(let text, let tokensIn, let tokensOut) = event.payload else {
            return XCTFail("Expected .assistantMessageCompleted")
        }
        XCTAssertEqual(text, "")
        XCTAssertEqual(tokensIn, 1500)
        XCTAssertEqual(tokensOut, 320)

        guard let ext = event.providerExtensions,
              case .nested(let antigravity) = ext["antigravity"] else {
            return XCTFail("Expected antigravity extension fields")
        }
        XCTAssertEqual(antigravity["source"], .string("db"))
        XCTAssertEqual(antigravity["conversation_uuid"], .string("uuid-1"))
        XCTAssertEqual(antigravity["model_name"], .string("gemini-3.1-pro"))
        XCTAssertEqual(antigravity["match_count"], .int(3))
        XCTAssertEqual(antigravity["cached_tokens"], .int(4200))
        XCTAssertEqual(antigravity["reasoning_tokens"], .int(100))
        XCTAssertEqual(antigravity["cwd"], .string("/Users/x/myrepo"))
    }

    func test_translate_dbUsage_emptyRollup_emitsNothing() {
        let events = AntigravityAdapter.translate(
            dbUsage: .empty,
            conversationUUID: "uuid-1",
            timestamp: timestamp,
            modelName: "gemini-3.1-pro",
            cwd: nil,
            sessionId: "session-1",
            sequenceNumber: 0
        )
        // Matches AntigravityDBUsageParser's empty-fallback contract:
        // no records → no canonical event (caller falls back to .pb
        // estimator path if needed).
        XCTAssertEqual(events.count, 0)
    }

    // MARK: - .pb legacy path

    func test_translate_legacyRecord_emitsAssistantMessageCompleted() {
        let record = UsageRecord(
            provider: .gemini,
            timestamp: timestamp,
            model: "gemini-3.1-pro",
            tokens: TokenTotals(
                inputTokens: 1000,
                outputTokens: 500,
                cacheCreationTokens: 0,
                cacheReadTokens: 200,
                reasoningTokens: 50,
                costUSD: 0
            ),
            repo: nil,
            dedupKey: "legacy-1"
        )
        let events = AntigravityAdapter.translate(
            legacyRecord: record,
            conversationUUID: "uuid-2",
            sessionId: "session-1",
            sequenceNumber: 0
        )
        XCTAssertEqual(events.count, 1)
        guard case .assistantMessageCompleted(_, let tokensIn, let tokensOut) = events[0].payload else {
            return XCTFail("Expected .assistantMessageCompleted")
        }
        XCTAssertEqual(tokensIn, 1000)
        XCTAssertEqual(tokensOut, 500)

        guard let ext = events[0].providerExtensions,
              case .nested(let antigravity) = ext["antigravity"] else {
            return XCTFail("Expected antigravity extension fields")
        }
        XCTAssertEqual(antigravity["source"], .string("pb"))
        XCTAssertEqual(antigravity["is_estimated"], .bool(true))
        XCTAssertEqual(antigravity["cache_read_tokens"], .int(200))
        XCTAssertEqual(antigravity["reasoning_tokens"], .int(50))
    }

    func test_translate_legacyRecord_canMarkNonEstimated() {
        // If a future .pb decryption story succeeds, callers can pass
        // isEstimated:false to signal high-confidence numbers.
        let record = UsageRecord(
            provider: .gemini,
            timestamp: timestamp,
            model: "gemini-3.1-pro",
            tokens: TokenTotals(
                inputTokens: 100, outputTokens: 50,
                cacheCreationTokens: 0, cacheReadTokens: 0,
                reasoningTokens: 0, costUSD: 0
            ),
            repo: nil,
            dedupKey: nil
        )
        let events = AntigravityAdapter.translate(
            legacyRecord: record,
            conversationUUID: "uuid-x",
            sessionId: "session-1",
            sequenceNumber: 0,
            isEstimated: false
        )
        XCTAssertEqual(events.count, 1)
        guard let ext = events[0].providerExtensions,
              case .nested(let antigravity) = ext["antigravity"] else {
            return XCTFail("Expected antigravity extension fields")
        }
        XCTAssertEqual(antigravity["is_estimated"], .bool(false))
    }

    // MARK: - Provider instance + raw bytes

    func test_dbUsage_propagatesInstanceIdAndRawBytes() {
        let usage = AntigravityDBUsage(
            inputTokens: 100, outputTokens: 50,
            cachedTokens: 0, reasoningTokens: 0,
            toolUseTokens: 0, recordCount: 1
        )
        let bytes = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let events = AntigravityAdapter.translate(
            dbUsage: usage,
            conversationUUID: "uuid-1",
            timestamp: timestamp,
            modelName: "gemini-3.1-pro",
            cwd: nil,
            sessionId: "session-1",
            sequenceNumber: 7,
            providerInstanceId: "antigravity_personal",
            rawBytes: bytes
        )
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].rawProviderPayload, bytes)
        XCTAssertEqual(events[0].providerInstanceId, "antigravity_personal")
        XCTAssertEqual(events[0].sequenceNumber, 7)
    }
#endif
}

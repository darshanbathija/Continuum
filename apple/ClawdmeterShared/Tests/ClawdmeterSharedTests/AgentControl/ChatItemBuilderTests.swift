import XCTest
@testable import ClawdmeterShared

/// Tests for the incremental ChatItemBuilder. Covers all five paths the
/// perf-overhaul plan calls out:
/// 1. Happy path: user → assistant → tool_use → tool_result → user
/// 2. Orphan tool_use (no matching tool_result) — flushed as run with nil result
/// 3. Malformed line / no message — silently dropped (CQ3' codex revert)
/// 4. Empty message stream — items stays empty
/// 5. Single message — appended as a single ChatItem.message
final class ChatItemBuilderTests: XCTestCase {

    func testHappyPathBucketsToolPair() {
        var b = ChatItemBuilder()
        let now = Date()
        b.ingest(.userText(at: now, body: "fix the auth bug", id: "u1"))
        b.ingest(.assistantText(at: now, body: "Looking at it now.", id: "a1"))
        b.ingest(.toolCall(at: now, name: "Read", body: "auth.swift",
                           toolUseId: "t1"))
        b.ingest(.toolResult(at: now, body: "10 lines",
                              toolUseId: "t1"))
        b.ingest(.userText(at: now, body: "great, ship it", id: "u2"))

        // Expect: [u1, a1, toolRun(t1), u2]
        XCTAssertEqual(b.items.count, 4)
        if case .message(let m1) = b.items[0] {
            XCTAssertEqual(m1.kind, .userText)
            XCTAssertEqual(m1.body, "fix the auth bug")
        } else { XCTFail("expected message at 0") }
        if case .toolRun(_, let pairs) = b.items[2] {
            XCTAssertEqual(pairs.count, 1)
            XCTAssertEqual(pairs[0].call.title, "Read")
            XCTAssertNotNil(pairs[0].result)
            XCTAssertEqual(pairs[0].result?.body, "10 lines")
        } else { XCTFail("expected toolRun at 2") }
    }

    func testOrphanToolUseFlushesAsRunWithNilResult() {
        var b = ChatItemBuilder()
        let now = Date()
        b.ingest(.toolCall(at: now, name: "Bash", body: "git status",
                           toolUseId: "t1"))
        // No matching tool_result — next prose flushes the pending run.
        b.ingest(.assistantText(at: now, body: "Done.", id: "a1"))

        XCTAssertEqual(b.items.count, 2)
        if case .toolRun(_, let pairs) = b.items[0] {
            XCTAssertEqual(pairs.count, 1)
            XCTAssertNil(pairs[0].result, "orphan tool_use should have nil result")
        } else { XCTFail("expected toolRun at 0") }
    }

    func testMalformedLineSkippedSilently() {
        // Simulate: caller skips lines that don't produce a ChatMessage at all.
        // The builder itself only sees real ChatMessages — but it should remain
        // consistent when caller skips lines. Test: a tool_use followed by
        // a (skipped) malformed line followed by its tool_result still pairs
        // correctly.
        var b = ChatItemBuilder()
        let now = Date()
        b.ingest(.toolCall(at: now, name: "Edit", body: "auth.swift",
                           toolUseId: "t1"))
        // (malformed line in the JSONL — caller dropped it, never reached us)
        b.ingest(.toolResult(at: now, body: "wrote 5 lines", toolUseId: "t1"))
        b.flushPending()  // explicit flush at EOF

        XCTAssertEqual(b.items.count, 1)
        if case .toolRun(_, let pairs) = b.items[0] {
            XCTAssertEqual(pairs.count, 1)
            XCTAssertNotNil(pairs[0].result)
        } else { XCTFail("expected toolRun") }
    }

    func testEmptyStreamHasEmptyItems() {
        let b = ChatItemBuilder()
        XCTAssertTrue(b.items.isEmpty)
    }

    func testSingleMessageAppendsOneItem() {
        var b = ChatItemBuilder()
        b.ingest(.userText(at: Date(), body: "hi", id: "u1"))
        XCTAssertEqual(b.items.count, 1)
        if case .message(let m) = b.items[0] {
            XCTAssertEqual(m.body, "hi")
            XCTAssertEqual(m.kind, .userText)
        } else { XCTFail("expected message") }
    }

    // MARK: - Reconciliation reorder (T4 prerequisite)

    func testToolPairResolvedAcrossOrderReverseTailReconciliation() {
        // Reverse-tail scenario: result arrives first, then call.
        // Today's builder drops the orphan result (.orphanResult delta).
        // Caller is responsible for re-ingesting in chronological order
        // during the reconciliation pass.
        var b = ChatItemBuilder()
        let now = Date()
        let delta = b.ingest(.toolResult(at: now, body: "ok", toolUseId: "t1"))
        XCTAssertEqual(delta, .orphanResult(toolUseId: "t1"))
        XCTAssertTrue(b.items.isEmpty, "orphan result alone produces no item")
    }

    // MARK: - Duplicate-id guard (/review hardening)

    func testDuplicateToolUseIdKeepsFirstAndDropsSecond() {
        // The /review pass spotted that a second .toolCall for an
        // already-pending tool_use_id would overwrite the prior
        // ToolPair (including any in-progress result) AND duplicate
        // the id in pendingOrder. After the guard, the first instance
        // wins and the second is silently dropped.
        var b = ChatItemBuilder()
        let now = Date()
        b.ingest(.toolCall(at: now, name: "Bash",
                           body: "first call", toolUseId: "t1"))
        b.ingest(.toolCall(at: now, name: "Bash",
                           body: "DUPLICATE call", toolUseId: "t1"))
        b.ingest(.toolResult(at: now, body: "ok", toolUseId: "t1"))
        b.ingest(.assistantText(at: now, body: "Done.", id: "a1"))

        // Expect ONE toolRun with ONE pair (the first call), result paired.
        // Plus one prose message.
        XCTAssertEqual(b.items.count, 2)
        guard case .toolRun(_, let pairs) = b.items[0] else {
            XCTFail("expected toolRun at index 0")
            return
        }
        XCTAssertEqual(pairs.count, 1, "duplicate id should NOT add a second pair")
        XCTAssertEqual(pairs[0].call.body, "first call",
                       "first call wins; duplicate dropped")
        XCTAssertNotNil(pairs[0].result, "result should still pair with the first call")
    }
}

// MARK: - Test fixture helpers

private extension ChatMessage {
    static func userText(at: Date, body: String, id: String) -> ChatMessage {
        ChatMessage(id: id, kind: .userText, title: "You", body: body, at: at)
    }
    static func assistantText(at: Date, body: String, id: String) -> ChatMessage {
        ChatMessage(id: id, kind: .assistantText, title: "Claude", body: body, at: at)
    }
    static func toolCall(at: Date, name: String, body: String, toolUseId: String) -> ChatMessage {
        ChatMessage(id: "call:\(toolUseId)", kind: .toolCall, title: name, body: body, at: at)
    }
    static func toolResult(at: Date, body: String, toolUseId: String,
                           isError: Bool = false) -> ChatMessage {
        ChatMessage(id: "result:\(toolUseId)", kind: .toolResult, title: "Tool result",
                    body: body, at: at, isError: isError)
    }
}

import XCTest
@testable import ClawdmeterShared

/// Tests for `ChatMessageOrdering` — the kind-based sort tiebreak the
/// hardening sprint extracted from `StagingParser.insertIndex` and
/// the step-extraction regex it shares with `computePlanSteps`.
///
/// The interesting invariant: on the same timestamp, `tool_use` MUST
/// sort before its matching `tool_result`. The previous design depended
/// on `"call:" < "result:"` lex ordering of ids, which Anthropic could
/// silently invalidate by changing prefixes to `tool_use:`/`tool_result:`.
/// These tests prove the typed-kind path holds across both conventions.
final class ChatMessageOrderingTests: XCTestCase {

    // MARK: - Fixture helpers

    private let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func msg(_ kind: ChatMessage.Kind,
                    id: String,
                    at: Date? = nil,
                    body: String = "") -> ChatMessage {
        ChatMessage(
            id: id, kind: kind, title: "x",
            body: body, at: at ?? baseDate
        )
    }

    // MARK: - Timestamp wins

    func testDifferentTimestamps_EarlierPrecedes() {
        let earlier = msg(.assistantText, id: "a", at: baseDate)
        let later = msg(.userText, id: "z", at: baseDate.addingTimeInterval(1))
        XCTAssertTrue(ChatMessageOrdering.precedes(earlier, later))
        XCTAssertFalse(ChatMessageOrdering.precedes(later, earlier))
    }

    // MARK: - Same timestamp, kind tiebreak

    func testSameTimestamp_ToolCallPrecedesToolResult_RegardlessOfIdPrefix() {
        // The bug-prone case: same timestamp, tool_use should sort
        // before tool_result. Try BOTH plausible id-prefix conventions
        // to prove the tiebreak doesn't depend on lex order.

        // 1) Current convention: "call:" < "result:" lex-wise (kind agrees).
        let call1 = msg(.toolCall, id: "call:abc")
        let result1 = msg(.toolResult, id: "result:abc")
        XCTAssertTrue(ChatMessageOrdering.precedes(call1, result1))

        // 2) Hypothetical future convention: "tool_use" lex > "tool_result"
        //    (because 'u' > 'r'). Pure-id sort would now put result BEFORE
        //    call — which would break ChatItemBuilder's pair grouping.
        //    Typed-kind sort still keeps call before result.
        let call2 = msg(.toolCall, id: "tool_use:abc")
        let result2 = msg(.toolResult, id: "tool_result:abc")
        XCTAssertTrue(ChatMessageOrdering.precedes(call2, result2))

        // 3) Even with deliberately-inverted ids — typed kind always wins.
        let callZ = msg(.toolCall, id: "zzzzz")
        let resultA = msg(.toolResult, id: "aaaaa")
        XCTAssertTrue(ChatMessageOrdering.precedes(callZ, resultA))
    }

    func testSameTimestamp_UserPrecedesAssistantPrecedesToolCallPrecedesToolResultPrecedesMeta() {
        let order: [ChatMessage.Kind] = [
            .userText, .assistantText, .toolCall, .toolResult, .meta
        ]
        for i in 0..<order.count {
            for j in 0..<order.count {
                let a = msg(order[i], id: "id-\(i)")
                let b = msg(order[j], id: "id-\(j)")
                if i < j {
                    XCTAssertTrue(
                        ChatMessageOrdering.precedes(a, b),
                        "\(order[i]) should precede \(order[j])"
                    )
                }
                if i == j {
                    // Same kind: tie falls through to id, expected id-i < id-j.
                    XCTAssertEqual(
                        ChatMessageOrdering.precedes(a, b),
                        "id-\(i)" < "id-\(j)"
                    )
                }
            }
        }
    }

    // MARK: - Same timestamp + same kind, id tiebreak

    func testSameTimestampAndKind_IdTiebreak() {
        let a = msg(.assistantText, id: "abc")
        let b = msg(.assistantText, id: "xyz")
        XCTAssertTrue(ChatMessageOrdering.precedes(a, b))
        XCTAssertFalse(ChatMessageOrdering.precedes(b, a))
    }

    // MARK: - kindRank stable mapping

    func testKindRankIsStableAndDeterministic() {
        XCTAssertEqual(ChatMessageOrdering.kindRank(.userText), 0)
        XCTAssertEqual(ChatMessageOrdering.kindRank(.assistantText), 1)
        XCTAssertEqual(ChatMessageOrdering.kindRank(.toolCall), 2)
        XCTAssertEqual(ChatMessageOrdering.kindRank(.toolResult), 3)
        XCTAssertEqual(ChatMessageOrdering.kindRank(.meta), 4)
    }

    // MARK: - extractStepCandidates regex

    func testExtractStepsNumberedList() {
        let body = """
        1. First the thing
        2. Then the other
        3. Finally
        """
        XCTAssertEqual(
            ChatMessageOrdering.extractStepCandidates(from: body),
            ["First the thing", "Then the other", "Finally"]
        )
    }

    func testExtractStepsStepNFormat() {
        let body = """
        Step 1: Read the file
        Step 2: Edit the function
        step 3 do the thing  (lowercase)
        """
        let steps = ChatMessageOrdering.extractStepCandidates(from: body)
        // Two with colon, one case-insensitive without colon — all match.
        XCTAssertEqual(steps, ["Read the file", "Edit the function", "do the thing  (lowercase)"])
    }

    func testExtractStepsMixedFormat() {
        let body = """
        Here's the plan:
        1. First do A
        Step 2: Then do B
        And some prose.
        3. Finally do C
        """
        XCTAssertEqual(
            ChatMessageOrdering.extractStepCandidates(from: body),
            ["First do A", "Then do B", "Finally do C"]
        )
    }

    func testExtractStepsIgnoresNonStepLines() {
        let body = "I think we should ship this. No numbered steps here."
        XCTAssertTrue(ChatMessageOrdering.extractStepCandidates(from: body).isEmpty)
    }

    func testExtractStepsHandlesEmpty() {
        XCTAssertTrue(ChatMessageOrdering.extractStepCandidates(from: "").isEmpty)
    }

    func testExtractStepsTrimsWhitespace() {
        let body = "  1.   hello world   "
        XCTAssertEqual(ChatMessageOrdering.extractStepCandidates(from: body),
                       ["hello world"])
    }

    // MARK: - Insertion-sort scenario (the actual call-site use case)

    func testInsertSortKeepsToolPairsTogetherAcrossTimestampTies() {
        // Simulate the reverse-tail + head merge: two messages share a
        // timestamp (Claude collapses tool roundtrip), and the pair
        // arrives in unpredictable order. After insertion-sort using
        // `precedes`, the call MUST land before the result regardless
        // of arrival order.
        var sorted: [ChatMessage] = []
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let result = msg(.toolResult, id: "result:t1", at: t, body: "ok")
        let call = msg(.toolCall, id: "call:t1", at: t, body: "git status")

        // Insert result first (reverse-tail arrival).
        sorted.insert(result, at: insertIndex(for: result, in: sorted))
        XCTAssertEqual(sorted.count, 1)
        // Then insert call.
        sorted.insert(call, at: insertIndex(for: call, in: sorted))
        XCTAssertEqual(sorted.count, 2)

        // Order MUST be [call, result].
        XCTAssertEqual(sorted[0].kind, .toolCall)
        XCTAssertEqual(sorted[1].kind, .toolResult)
    }

    /// Mirror of `StagingParser.insertIndex(for:)` so the sort-ordering
    /// scenario above is hermetic.
    private func insertIndex(for msg: ChatMessage, in sorted: [ChatMessage]) -> Int {
        var lo = 0
        var hi = sorted.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if ChatMessageOrdering.precedes(sorted[mid], msg) {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return lo
    }
}

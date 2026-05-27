import XCTest
import ClawdmeterShared
@testable import Clawdmeter

/// Pinned-prompt heuristic for `ChatSnapshot.currentTurnStartedAt`.
///
/// The live activity pill ("X.Xs · thinking…") binds to this value. Before
/// v0.30 it was implemented as `messages.last(where: { $0.kind ==
/// .userText })?.at`, which made the timer reset every 5-30s as Claude's
/// user-role JSONL frames carrying both `tool_result` AND a sibling
/// `text` block landed — the sibling text block produced a synthetic
/// `.userText` ChatMessage with the *current* event timestamp, replacing
/// the original prompt's timestamp.
///
/// The fix walks forward and skips any `.userText` whose preceding
/// message in the transcript is `.toolResult` (those are the tool-result
/// frame's sibling text blocks; they share a timestamp with the
/// `.toolResult` and aren't real prompts). Real prompts are preceded by
/// `.assistantText`, a plan settle, or nothing at all.
@MainActor
final class SessionChatStoreTurnTimerTests: XCTestCase {

    // MARK: - Helpers

    private func message(
        _ kind: ChatMessage.Kind,
        at: TimeInterval,
        body: String = ""
    ) -> ChatMessage {
        ChatMessage(
            id: "\(kind.rawValue)-\(at)",
            kind: kind,
            title: kind == .userText ? "You" : "Claude",
            body: body,
            at: Date(timeIntervalSince1970: at)
        )
    }

    private func snapshot(_ messages: [ChatMessage]) -> SessionChatStore.ChatSnapshot {
        SessionChatStore.ChatSnapshot(
            items: [],
            messages: messages,
            updateCounter: 0
        )
    }

    // MARK: - Real prompt → unchanged

    /// Simplest case: one prompt + assistant turn. Timer anchors to the
    /// prompt's timestamp.
    func test_firstPrompt_pinsTimerToPromptTimestamp() {
        let snap = snapshot([
            message(.userText, at: 0, body: "Make a banana"),
            message(.assistantText, at: 2),
        ])

        XCTAssertEqual(
            snap.currentTurnStartedAt,
            Date(timeIntervalSince1970: 0)
        )
    }

    /// The regression: tool-result frame carries a sibling text block,
    /// landing a synthetic `.userText` with the tool-result's timestamp.
    /// Pre-fix this clobbered the prompt time; post-fix the original
    /// prompt at T=0 wins.
    func test_syntheticUserTextAfterToolResult_doesNotResetTimer() {
        let snap = snapshot([
            message(.userText, at: 0, body: "Make a banana"),
            message(.assistantText, at: 2),
            message(.toolCall, at: 3, body: "Bash"),
            message(.toolResult, at: 5, body: "stdout"),
            // Synthetic — same timestamp as the toolResult above. This
            // is the line that USED to reset the timer.
            message(.userText, at: 5, body: "continue"),
            message(.assistantText, at: 6),
        ])

        XCTAssertEqual(
            snap.currentTurnStartedAt,
            Date(timeIntervalSince1970: 0),
            "synthetic .userText injected by a tool-result frame must NOT advance the turn-start anchor"
        )
    }

    /// A genuinely new user prompt after the prior turn settles must
    /// advance the anchor. The previous turn's `.assistantText` is the
    /// settle marker — a `.userText` following it is real.
    func test_newPromptAfterAssistantSettle_advancesTimer() {
        let snap = snapshot([
            message(.userText, at: 0, body: "First"),
            message(.assistantText, at: 4),
            // ~16 seconds pass; user sends a follow-up.
            message(.userText, at: 20, body: "Follow up"),
            message(.assistantText, at: 22),
        ])

        XCTAssertEqual(
            snap.currentTurnStartedAt,
            Date(timeIntervalSince1970: 20),
            "a .userText preceded by .assistantText is a real follow-up prompt and must reset the timer"
        )
    }

    /// Mixed case: real prompt, mid-turn synthetic injection, then a real
    /// follow-up after settle. The real follow-up wins.
    func test_realPromptAfterSyntheticInjection_winsOverPriorTurn() {
        let snap = snapshot([
            message(.userText, at: 0, body: "Original"),
            message(.assistantText, at: 1),
            message(.toolCall, at: 2, body: "Bash"),
            message(.toolResult, at: 3, body: "stdout"),
            message(.userText, at: 3, body: "continue (synthetic)"),
            message(.assistantText, at: 4, body: "I'm done"),
            // Real follow-up
            message(.userText, at: 20, body: "Follow up"),
            message(.assistantText, at: 21),
        ])

        XCTAssertEqual(
            snap.currentTurnStartedAt,
            Date(timeIntervalSince1970: 20)
        )
    }

    /// Edge case: only one message, a synthetic-looking `.userText`
    /// following a `.toolResult` from a prior session (no real prompt
    /// visible in the window). The heuristic falls back to the last
    /// `.userText` rather than returning nil — better to show a slightly
    /// inflated timer than to blank the activity pill entirely.
    func test_onlyUserTextIsSyntheticLike_fallsBackRatherThanReturningNil() {
        let snap = snapshot([
            // Imagine the chat was paginated and the only history we
            // can see starts with a tool result. The .userText here
            // looks synthetic but it's all we have.
            message(.toolResult, at: 100, body: "stdout"),
            message(.userText, at: 100, body: "continue"),
            message(.assistantText, at: 102),
        ])

        XCTAssertEqual(
            snap.currentTurnStartedAt,
            Date(timeIntervalSince1970: 100),
            "fallback branch must return the last .userText we have rather than nil — empty pill is worse than slightly-off pill"
        )
    }

    /// No `.userText` at all → nil. The activity pill hides via its own
    /// `isActive(at:)` check when there's no anchor.
    func test_noUserTextAtAll_returnsNil() {
        let snap = snapshot([
            message(.assistantText, at: 0),
            message(.toolCall, at: 1, body: "Bash"),
        ])

        XCTAssertNil(snap.currentTurnStartedAt)
    }

    /// Empty snapshot → nil.
    func test_emptyMessages_returnsNil() {
        let snap = snapshot([])

        XCTAssertNil(snap.currentTurnStartedAt)
    }
}

import XCTest
@testable import ClawdmeterShared

/// Covers the transcript→priming-context serializer used when a harness session
/// is respawned with new model/effort/approval. The provider thread restarts
/// with no memory, so this block re-hands it the conversation.
final class HarnessTranscriptContextTests: XCTestCase {

    private func msg(_ kind: ChatMessage.Kind, _ title: String, _ body: String) -> ChatMessage {
        ChatMessage(id: UUID().uuidString, kind: kind, title: title, body: body, at: Date(timeIntervalSince1970: 0))
    }

    func testEmptyTranscriptReturnsNil() {
        XCTAssertNil(HarnessTranscriptContext.preamble(from: []))
    }

    func testWhitespaceAndToolOnlyTranscriptReturnsNil() {
        let messages = [
            msg(.userText, "You", "   "),
            msg(.toolCall, "Bash", "ls -la"),
            msg(.toolResult, "Bash", "file1\nfile2"),
            msg(.meta, "meta", "session started"),
        ]
        XCTAssertNil(HarnessTranscriptContext.preamble(from: messages),
                     "Only tool/meta/blank turns carry nothing worth re-priming")
    }

    func testIncludesUserAndAssistantInOrderSkipsTools() {
        let messages = [
            msg(.userText, "You", "add a login screen"),
            msg(.toolCall, "Edit", "Login.swift"),
            msg(.toolResult, "Edit", "+40 -0"),
            msg(.assistantText, "Grok", "Done — added Login.swift"),
        ]
        let out = try? XCTUnwrap(HarnessTranscriptContext.preamble(from: messages))
        let preamble = out ?? ""
        XCTAssertTrue(preamble.contains("User: add a login screen"))
        XCTAssertTrue(preamble.contains("Assistant: Done — added Login.swift"))
        XCTAssertFalse(preamble.contains("Login.swift\n"), "tool rows must be excluded")
        XCTAssertFalse(preamble.contains("+40 -0"))
        // User turn appears before the assistant turn.
        let u = preamble.range(of: "User: add a login screen")!
        let a = preamble.range(of: "Assistant: Done")!
        XCTAssertTrue(u.lowerBound < a.lowerBound)
        // Carries the resume framing.
        XCTAssertTrue(preamble.contains("[Context hand-off]"))
    }

    func testRecencyCapKeepsNewestTurnsAndFlagsTruncation() {
        // 50 user turns of ~100 chars each; a tight cap keeps only the tail.
        var messages: [ChatMessage] = []
        for i in 0..<50 {
            messages.append(msg(.userText, "You", "turn-\(i) " + String(repeating: "x", count: 90)))
        }
        let preamble = try? XCTUnwrap(HarnessTranscriptContext.preamble(from: messages, maxChars: 400))
        let text = preamble ?? ""
        XCTAssertTrue(text.contains("turn-49"), "newest turn must be kept")
        XCTAssertFalse(text.contains("turn-0 "), "oldest turn must be dropped under the cap")
        XCTAssertTrue(text.contains("older turns omitted"), "truncation must be disclosed to the model")
    }

    func testNoTruncationNoteWhenEverythingFits() {
        let preamble = try? XCTUnwrap(HarnessTranscriptContext.preamble(from: [
            msg(.userText, "You", "hello"),
            msg(.assistantText, "Grok", "hi"),
        ]))
        XCTAssertFalse((preamble ?? "").contains("older turns omitted"))
    }
}

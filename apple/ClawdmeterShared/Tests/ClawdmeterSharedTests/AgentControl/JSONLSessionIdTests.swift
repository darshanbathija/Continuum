import XCTest
@testable import ClawdmeterShared

final class JSONLSessionIdTests: XCTestCase {

    private func write(_ contents: String, line: UInt = #line) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jsonl-test-\(UUID().uuidString).jsonl")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func test_claude_happyPath_extractsSessionId() throws {
        let url = try write(#"{"sessionId":"abc-123","type":"user"}"# + "\n")
        XCTAssertEqual(JSONLSessionId.extract(from: url, provider: .claude), "abc-123")
    }

    func test_codex_happyPath_extractsPayloadId() throws {
        let url = try write(#"{"type":"session_meta","payload":{"id":"xyz-789","cwd":"/"}}"# + "\n")
        XCTAssertEqual(JSONLSessionId.extract(from: url, provider: .codex), "xyz-789")
    }

    func test_missingFile_returnsNil() {
        let url = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).jsonl")
        XCTAssertNil(JSONLSessionId.extract(from: url, provider: .claude))
    }

    func test_emptyFile_returnsNil() throws {
        let url = try write("")
        XCTAssertNil(JSONLSessionId.extract(from: url, provider: .claude))
    }

    func test_emptyId_returnsNil() throws {
        let url = try write(#"{"sessionId":""}"# + "\n")
        XCTAssertNil(JSONLSessionId.extract(from: url, provider: .claude))
    }

    func test_wrongProvider_returnsNil() throws {
        // Claude file scanned as Codex — no session_meta, returns nil.
        let url = try write(#"{"sessionId":"abc"}"# + "\n")
        XCTAssertNil(JSONLSessionId.extract(from: url, provider: .codex))
    }

    func test_codex_leadingNewline_tolerated() throws {
        let url = try write("\n" + #"{"type":"session_meta","payload":{"id":"x"}}"# + "\n")
        XCTAssertEqual(JSONLSessionId.extract(from: url, provider: .codex), "x")
    }

    func test_malformedJSONLine_skipped() throws {
        let url = try write("not-json\n" + #"{"sessionId":"good"}"# + "\n")
        XCTAssertEqual(JSONLSessionId.extract(from: url, provider: .claude), "good")
    }

    func test_codex_skipsNonMetaLinesUntilMeta() throws {
        let url = try write(
            #"{"type":"event_msg","payload":{}}"# + "\n" +
            #"{"type":"session_meta","payload":{"id":"later"}}"# + "\n"
        )
        XCTAssertEqual(JSONLSessionId.extract(from: url, provider: .codex), "later")
    }

    func test_largeLeadingPayload_within64KB_found() throws {
        // Codex `session_meta` lines can carry a multi-KB `base_instructions`.
        // The post-review 64KB read should comfortably cover ~10KB headers.
        let pad = String(repeating: "x", count: 10 * 1024)
        let url = try write(#"{"type":"session_meta","payload":{"id":"big","instructions":"\#(pad)"}}"# + "\n")
        XCTAssertEqual(JSONLSessionId.extract(from: url, provider: .codex), "big")
    }
}

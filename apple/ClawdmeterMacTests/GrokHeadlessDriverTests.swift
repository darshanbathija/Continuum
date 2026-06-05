import XCTest
@testable import Clawdmeter
import ClawdmeterShared

/// Locks the grok streaming-json → HarnessEvent mapping (verified against the
/// real `grok --output-format streaming-json` output, 2026-06-03).
final class GrokHeadlessDriverTests: XCTestCase {
    private func parse(_ s: String) -> HarnessEvent? {
        GrokHeadlessDriver.parseLine(Data(s.utf8))
    }

    func test_textDelta_mapsToAgentMessageDelta() {
        XCTAssertEqual(parse(#"{"type":"text","data":"OK"}"#), .agentMessageDelta("OK"))
    }

    func test_thoughtDelta_mapsToAgentThoughtDelta() {
        XCTAssertEqual(parse(#"{"type":"thought","data":"The user"}"#), .agentThoughtDelta("The user"))
    }

    func test_error_mapsToError() {
        XCTAssertEqual(parse(#"{"type":"error","data":"boom"}"#), .error(code: "grok", message: "boom"))
    }

    func test_emptyDelta_isDropped() {
        XCTAssertNil(parse(#"{"type":"text","data":""}"#))
        XCTAssertNil(parse(#"{"type":"thought","data":""}"#))
    }

    func test_unknownType_isDropped() {
        XCTAssertNil(parse(#"{"type":"tool_call","data":"x"}"#))
        XCTAssertNil(parse(#"{"type":"session_update","data":"x"}"#))
    }

    func test_usage_mapsToHarnessUsage() {
        XCTAssertEqual(
            parse(#"{"type":"usage","data":{"input_tokens":12,"output_tokens":7,"total_tokens":19}}"#),
            .usage(HarnessUsage(inputTokens: 12, outputTokens: 7, totalTokens: 19))
        )
    }

    func test_usageUpdate_mapsStringifiedPayload() {
        XCTAssertEqual(
            parse(#"{"type":"usage_update","data":"{\"prompt_tokens\":\"3\",\"completion_tokens\":4,\"total_tokens\":7}"}"#),
            .usage(HarnessUsage(inputTokens: 3, outputTokens: 4, totalTokens: 7))
        )
    }

    func test_malformed_isDropped() {
        XCTAssertNil(parse("not json at all"))
        XCTAssertNil(parse(""))
        XCTAssertNil(parse(#"{"no_type":true}"#))
    }
}

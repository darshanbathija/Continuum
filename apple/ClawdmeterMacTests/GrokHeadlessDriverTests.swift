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
        XCTAssertNil(parse(#"{"type":"usage","data":"x"}"#))
    }

    func test_malformed_isDropped() {
        XCTAssertNil(parse("not json at all"))
        XCTAssertNil(parse(""))
        XCTAssertNil(parse(#"{"no_type":true}"#))
    }
}

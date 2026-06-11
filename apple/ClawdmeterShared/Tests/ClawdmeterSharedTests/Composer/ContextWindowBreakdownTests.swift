import XCTest
@testable import ClawdmeterShared

final class ContextWindowBreakdownTests: XCTestCase {
    func test_fromACPUpdate_parsesSnakeCaseBreakdown() {
        let update: ACPJSONValue = .object([
            "sessionUpdate": .string("context_window_update"),
            "context_window": .object([
                "used_tokens": .int(409_000),
                "limit_tokens": .int(1_000_000),
                "breakdown": .object([
                    "mcp_tools": .int(222_000),
                    "messages": .int(127_000),
                    "memory_files": .int(31_000),
                    "system_tools": .int(28_000),
                    "skills": .int(6_000),
                    "system_prompt": .int(5_000),
                    "custom_agents": .int(0),
                ]),
            ]),
        ])

        let note = ACPSessionNotification(
            sessionId: "s",
            update: ACPSessionUpdate(
                kind: .contextWindowUpdate,
                rawKind: "context_window_update",
                raw: update
            )
        )
        var titles: [String: String] = [:]
        let events = ACPEventMapper.map(note, toolTitles: &titles)

        guard case .contextBreakdown(let breakdown) = events.first else {
            return XCTFail("Expected contextBreakdown event")
        }
        XCTAssertEqual(breakdown.usedTokens, 409_000)
        XCTAssertEqual(breakdown.limitTokens, 1_000_000)
        XCTAssertEqual(breakdown.headerText, "409.0k / 1.0M")
        XCTAssertEqual(breakdown.displayEntries.first?.id, .freeSpace)
        XCTAssertEqual(breakdown.entries.first { $0.id == .mcpTools }?.tokens, 222_000)
    }

    func test_estimate_buildsFreeSpaceAndConsumedRows() throws {
        let now = Date()
        let messages = [
            ChatMessage(id: "u1", kind: .userText, title: "You", body: String(repeating: "hello ", count: 400), at: now),
            ChatMessage(id: "a1", kind: .assistantText, title: "Assistant", body: String(repeating: "world ", count: 400), at: now),
        ]
        let breakdown = ContextWindowBreakdownParser.estimate(
            usedTokens: 40_000,
            limitTokens: 200_000,
            messages: messages
        )

        let unwrapped = try XCTUnwrap(breakdown)
        XCTAssertEqual(unwrapped.usedTokens, 40_000)
        XCTAssertEqual(unwrapped.limitTokens, 200_000)
        XCTAssertNotNil(unwrapped.entries.first { $0.id == ContextWindowBreakdown.CategoryID.freeSpace })
        XCTAssertNotNil(unwrapped.entries.first { $0.id == ContextWindowBreakdown.CategoryID.messages })
        XCTAssertGreaterThan(unwrapped.displayEntries.count, 1)
    }
}

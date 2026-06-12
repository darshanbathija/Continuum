import XCTest
@testable import ClawdmeterShared

final class SpawnPlanTests: XCTestCase {

    // MARK: - Slot expansion + ordering

    func testSlotsOrderMostToLeast() {
        // "4 claude, 2 codex and 2 cursor" → claude tiles spawn first.
        let slots = SpawnPlan.slots(for: [
            SpawnAgentAllocation(agent: .cursor, count: 2),
            SpawnAgentAllocation(agent: .claude, count: 4),
            SpawnAgentAllocation(agent: .codex, count: 2),
        ])
        XCTAssertEqual(slots.count, 8)
        XCTAssertEqual(slots.prefix(4).map(\.agent), [.claude, .claude, .claude, .claude])
        // Tie between cursor (2) and codex (2) keeps caller order: cursor first.
        XCTAssertEqual(slots[4...5].map(\.agent), [.cursor, .cursor])
        XCTAssertEqual(slots[6...7].map(\.agent), [.codex, .codex])
    }

    func testSlotsNumberWithinKind() {
        let slots = SpawnPlan.slots(for: [
            SpawnAgentAllocation(agent: .claude, count: 2),
            SpawnAgentAllocation(agent: .codex, count: 1),
        ])
        XCTAssertEqual(slots.map(\.title), ["Claude 1", "Claude 2", "Codex 1"])
    }

    func testSlotsSkipZeroAndNegativeCounts() {
        let slots = SpawnPlan.slots(for: [
            SpawnAgentAllocation(agent: .claude, count: 0),
            SpawnAgentAllocation(agent: .codex, count: -3),
            SpawnAgentAllocation(agent: .grok, count: 1),
        ])
        XCTAssertEqual(slots.map(\.agent), [.grok])
        XCTAssertEqual(slots.map(\.title), ["Grok 1"])
    }

    func testSlotsEmptyAllocationYieldsNoSlots() {
        XCTAssertTrue(SpawnPlan.slots(for: []).isEmpty)
    }

    func testSlotsMergeDuplicateAgentEntries() {
        // Duplicate entries for the same agent must not restart numbering:
        // [claude:2, claude:2] is 4 distinct tiles, not "Claude 1/2" twice.
        let slots = SpawnPlan.slots(for: [
            SpawnAgentAllocation(agent: .claude, count: 2),
            SpawnAgentAllocation(agent: .codex, count: 3),
            SpawnAgentAllocation(agent: .claude, count: 2),
        ])
        XCTAssertEqual(slots.map(\.title), [
            "Claude 1", "Claude 2", "Claude 3", "Claude 4",
            "Codex 1", "Codex 2", "Codex 3",
        ])
    }

    // MARK: - Grid shape

    func testGridColumnsForOfferedCounts() {
        XCTAssertEqual(SpawnPlan.gridColumns(forTileCount: 4), 2) // 2×2
        XCTAssertEqual(SpawnPlan.gridColumns(forTileCount: 6), 3) // 3×2
        XCTAssertEqual(SpawnPlan.gridColumns(forTileCount: 8), 4) // 4×2
    }

    func testGridColumnsForIntermediateCounts() {
        // Tiles can be closed individually mid-session.
        XCTAssertEqual(SpawnPlan.gridColumns(forTileCount: 0), 1)
        XCTAssertEqual(SpawnPlan.gridColumns(forTileCount: 1), 1)
        XCTAssertEqual(SpawnPlan.gridColumns(forTileCount: 2), 2)
        XCTAssertEqual(SpawnPlan.gridColumns(forTileCount: 3), 2)
        XCTAssertEqual(SpawnPlan.gridColumns(forTileCount: 5), 3)
        XCTAssertEqual(SpawnPlan.gridColumns(forTileCount: 7), 4)
        XCTAssertEqual(SpawnPlan.gridColumns(forTileCount: 9), 4)
    }

    // MARK: - Allocation bookkeeping

    func testSeededAllocationUsesFirstAvailableAgent() {
        XCTAssertEqual(
            SpawnPlan.seededAllocation(total: 4, availableAgents: [.claude, .codex]),
            [.claude: 4]
        )
        XCTAssertEqual(
            SpawnPlan.seededAllocation(total: 6, availableAgents: [.codex]),
            [.codex: 6]
        )
        XCTAssertTrue(SpawnPlan.seededAllocation(total: 4, availableAgents: []).isEmpty)
        XCTAssertTrue(SpawnPlan.seededAllocation(total: 0, availableAgents: [.claude]).isEmpty)
    }

    func testRebalanceGrowAddsToFirstAvailableAgent() {
        let out = SpawnPlan.rebalancedAllocation(
            [.claude: 2, .codex: 2],
            total: 6,
            availableAgents: [.claude, .codex]
        )
        XCTAssertEqual(out, [.claude: 4, .codex: 2])
    }

    func testRebalanceGrowWithNoAvailableAgentIsNoOp() {
        let out = SpawnPlan.rebalancedAllocation(
            [.claude: 2],
            total: 6,
            availableAgents: []
        )
        XCTAssertEqual(out, [.claude: 2])
    }

    func testRebalanceShrinksFromBottomOfDisplayOrderUpward() {
        // 8 → 4 with claude/codex/cursor allocated: trim cursor first (last
        // in display order), then codex, leaving claude untouched.
        let out = SpawnPlan.rebalancedAllocation(
            [.claude: 4, .codex: 2, .cursor: 2],
            total: 4,
            availableAgents: [.claude, .codex, .cursor]
        )
        XCTAssertEqual(out[.claude], 4)
        XCTAssertEqual(out[.codex], 0)
        XCTAssertEqual(out[.cursor], 0)
    }

    func testRebalancePartialTrimStopsAtTarget() {
        // 8 → 6: only cursor's 2 are trimmed.
        let out = SpawnPlan.rebalancedAllocation(
            [.claude: 4, .codex: 2, .cursor: 2],
            total: 6,
            availableAgents: [.claude, .codex, .cursor]
        )
        XCTAssertEqual(out, [.claude: 4, .codex: 2, .cursor: 0])
    }

    func testRebalanceAlreadyConsistentIsIdentity() {
        let counts: [AgentKind: Int] = [.claude: 4]
        XCTAssertEqual(
            SpawnPlan.rebalancedAllocation(counts, total: 4, availableAgents: [.claude]),
            counts
        )
    }

    // MARK: - Config invariants

    func testSessionCountOptions() {
        XCTAssertEqual(SpawnPlan.sessionCountOptions, [4, 6, 8])
    }

    func testSelectableAgentsExcludeUnknown() {
        XCTAssertFalse(SpawnPlan.selectableAgents.contains(.unknown))
        XCTAssertTrue(SpawnPlan.selectableAgents.contains(.claude))
        XCTAssertTrue(SpawnPlan.selectableAgents.contains(.codex))
        XCTAssertTrue(SpawnPlan.selectableAgents.contains(.cursor))
    }
}

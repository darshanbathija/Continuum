import XCTest
import ClawdmeterShared
@testable import Clawdmeter

/// Spawn-mode store bookkeeping: group/tile lifecycle, selection fallback,
/// exited-tile tracking, and failure surfacing. Tiles are seeded through the
/// `launchArgvOverride` test seam with hermetic binaries (`/bin/cat` blocks
/// on stdin forever; `/usr/bin/true` exits immediately) — same pattern as
/// the TerminalPtyHost tests, no real agent CLIs involved.
@MainActor
final class SpawnModeStoreTests: XCTestCase {

    private func makeStore(argv: [String]? = ["/bin/cat"]) -> SpawnModeStore {
        let store = SpawnModeStore()
        store.launchArgvOverride = { _ in argv }
        return store
    }

    private func drainTeardown(_ store: SpawnModeStore) async {
        // closeGroup/closeTile kill hosts on detached tasks; give them a
        // beat so child processes don't outlive the test process.
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    // MARK: - Creation

    func testCreateGroupSpawnsTilesMostToLeastAndSelects() async {
        let store = makeStore()
        let result = await store.createGroup(allocations: [
            SpawnAgentAllocation(agent: .codex, count: 1),
            SpawnAgentAllocation(agent: .claude, count: 2),
        ])
        guard let group = result.group else {
            return XCTFail("expected a group")
        }
        XCTAssertEqual(group.name, "Spawn 1")
        XCTAssertEqual(group.tiles.map(\.agent), [.claude, .claude, .codex])
        XCTAssertEqual(group.tiles.map(\.title), ["Claude 1", "Claude 2", "Codex 1"])
        XCTAssertEqual(store.selectedGroupId, group.id)
        XCTAssertEqual(store.selectedTileByGroup[group.id], group.tiles.first?.id)
        XCTAssertTrue(result.failedSlotTitles.isEmpty)
        XCTAssertEqual(group.agentSummary, "2 Claude · 1 Codex")
        store.closeGroup(id: group.id)
        await drainTeardown(store)
    }

    func testCreateGroupAllSlotsFailedReturnsNilAndKeepsSpawnNumber() async {
        let store = makeStore(argv: nil)  // no binary resolvable
        let failed = await store.createGroup(allocations: [
            SpawnAgentAllocation(agent: .claude, count: 2),
        ])
        XCTAssertNil(failed.group)
        XCTAssertEqual(failed.failedSlotTitles, ["Claude 1", "Claude 2"])
        XCTAssertTrue(store.groups.isEmpty)

        // The failed batch must not consume "Spawn 1".
        store.launchArgvOverride = { _ in ["/bin/cat"] }
        let ok = await store.createGroup(allocations: [
            SpawnAgentAllocation(agent: .claude, count: 1),
        ])
        XCTAssertEqual(ok.group?.name, "Spawn 1")
        if let id = ok.group?.id {
            store.closeGroup(id: id)
        }
        await drainTeardown(store)
    }

    func testFastExitingChildIsMarkedExited() async {
        let store = makeStore(argv: ["/usr/bin/true"])
        let result = await store.createGroup(allocations: [
            SpawnAgentAllocation(agent: .claude, count: 1),
        ])
        guard let tileId = result.group?.tiles.first?.id else {
            return XCTFail("expected one tile")
        }
        // Exit arrives asynchronously; poll briefly.
        for _ in 0..<40 where !store.exitedTileIds.contains(tileId) {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(store.exitedTileIds.contains(tileId),
                      "a child that exits immediately must still surface as exited")
        if let id = result.group?.id { store.closeGroup(id: id) }
        await drainTeardown(store)
    }

    // MARK: - Tile lifecycle

    func testCloseTileFallsBackSelectionAndAutoClosesEmptyGroup() async {
        let store = makeStore()
        let result = await store.createGroup(allocations: [
            SpawnAgentAllocation(agent: .claude, count: 2),
        ])
        guard let group = result.group, group.tiles.count == 2 else {
            return XCTFail("expected two tiles")
        }
        let first = group.tiles[0].id
        let second = group.tiles[1].id
        XCTAssertEqual(store.selectedTileByGroup[group.id], first)

        store.closeTile(groupId: group.id, tileId: first)
        XCTAssertEqual(store.selectedTileByGroup[group.id], second,
                       "selection falls back to the first remaining tile")
        XCTAssertEqual(store.group(id: group.id)?.tiles.count, 1)

        store.closeTile(groupId: group.id, tileId: second)
        XCTAssertNil(store.group(id: group.id), "last tile closes the group")
        XCTAssertNil(store.selectedGroupId)
        XCTAssertNil(store.selectedTileByGroup[group.id])
        await drainTeardown(store)
    }

    func testCreateGroupRecordsCapacityFromLaunchedTiles() async {
        let store = makeStore()
        let result = await store.createGroup(allocations: [
            SpawnAgentAllocation(agent: .claude, count: 3),
        ])
        guard let group = result.group else { return XCTFail("expected a group") }
        XCTAssertEqual(group.capacity, 3, "capacity is the count that actually launched")
        store.closeGroup(id: group.id)
        await drainTeardown(store)
    }

    func testAddTileRefillsClosedSlotWithContinuedNumbering() async {
        let store = makeStore()
        let result = await store.createGroup(allocations: [
            SpawnAgentAllocation(agent: .claude, count: 2),
        ])
        guard let group = result.group, group.tiles.count == 2 else {
            return XCTFail("expected two tiles")
        }
        XCTAssertEqual(group.capacity, 2)

        // Close the FIRST tile so a naive count-based name ("Claude 2") would
        // collide with the still-live "Claude 2".
        store.closeTile(groupId: group.id, tileId: group.tiles[0].id)
        XCTAssertEqual(store.group(id: group.id)?.tiles.count, 1)

        let added = await store.addTile(groupId: group.id, agent: .claude)
        XCTAssertTrue(added)
        let refilled = store.group(id: group.id)
        XCTAssertEqual(refilled?.tiles.count, 2, "the empty cell is refilled")
        XCTAssertEqual(refilled?.capacity, 2, "capacity is fixed at creation")
        XCTAssertEqual(refilled?.tiles.last?.title, "Claude 3",
                       "numbering continues past the highest live index")
        XCTAssertEqual(store.selectedTileByGroup[group.id], refilled?.tiles.last?.id,
                       "the refilled tile becomes the typing target")
        store.closeGroup(id: group.id)
        await drainTeardown(store)
    }

    func testAddTileRefusesWhenGroupAlreadyAtCapacity() async {
        let store = makeStore()
        let result = await store.createGroup(allocations: [
            SpawnAgentAllocation(agent: .claude, count: 1),
        ])
        guard let group = result.group else { return XCTFail("expected a group") }
        let added = await store.addTile(groupId: group.id, agent: .claude)
        XCTAssertFalse(added, "a full group has no empty cell to refill")
        XCTAssertEqual(store.group(id: group.id)?.tiles.count, 1)
        store.closeGroup(id: group.id)
        await drainTeardown(store)
    }

    func testAddTileToMissingGroupReturnsFalse() async {
        let store = makeStore()
        let added = await store.addTile(groupId: UUID(), agent: .claude)
        XCTAssertFalse(added)
        await drainTeardown(store)
    }

    func testCloseGroupClearsPerGroupState() async {
        let store = makeStore()
        let result = await store.createGroup(allocations: [
            SpawnAgentAllocation(agent: .claude, count: 1),
        ])
        guard let group = result.group, let tileId = group.tiles.first?.id else {
            return XCTFail("expected a tile")
        }
        store.toggleExpanded(groupId: group.id, tileId: tileId)
        XCTAssertEqual(store.expandedTileByGroup[group.id], tileId)

        store.closeGroup(id: group.id)
        XCTAssertTrue(store.groups.isEmpty)
        XCTAssertNil(store.selectedGroupId)
        XCTAssertNil(store.selectedTileByGroup[group.id])
        XCTAssertNil(store.expandedTileByGroup[group.id])
        XCTAssertFalse(store.exitedTileIds.contains(tileId))
        await drainTeardown(store)
    }

    func testToggleExpandedSelectsAndCompacts() async {
        let store = makeStore()
        let result = await store.createGroup(allocations: [
            SpawnAgentAllocation(agent: .claude, count: 2),
        ])
        guard let group = result.group, group.tiles.count == 2 else {
            return XCTFail("expected two tiles")
        }
        let second = group.tiles[1].id
        store.toggleExpanded(groupId: group.id, tileId: second)
        XCTAssertEqual(store.expandedTileByGroup[group.id], second)
        XCTAssertEqual(store.selectedTileByGroup[group.id], second,
                       "expanding a tile makes it the typing target")
        store.toggleExpanded(groupId: group.id, tileId: second)
        XCTAssertNil(store.expandedTileByGroup[group.id], "second toggle compacts")
        store.closeGroup(id: group.id)
        await drainTeardown(store)
    }

    // MARK: - Resize (grid header size toggle)

    func testResizeLargerGrowsCurrentGroupInPlace() async {
        let store = makeStore()
        let result = await store.createGroup(allocations: [
            SpawnAgentAllocation(agent: .claude, count: 2),
        ])
        guard let group = result.group else { return XCTFail("expected a group") }
        XCTAssertEqual(group.capacity, 2)

        let ok = await store.resizeGroup(groupId: group.id, to: 4)
        XCTAssertTrue(ok)
        XCTAssertEqual(store.groups.count, 1, "growing reuses the same spawn group")
        let grown = store.group(id: group.id)
        XCTAssertEqual(grown?.tiles.count, 4)
        XCTAssertEqual(grown?.capacity, 4, "capacity bumps so the grid reshapes to 4 cells")
        XCTAssertEqual(grown?.tiles.map(\.agent), [.claude, .claude, .claude, .claude],
                       "new tiles refill into the dominant agent")
        XCTAssertEqual(grown?.tiles.map(\.title),
                       ["Claude 1", "Claude 2", "Claude 3", "Claude 4"],
                       "numbering continues past the existing tiles")
        XCTAssertEqual(store.selectedGroupId, group.id, "selection stays on the grown spawn")
        store.closeGroup(id: group.id)
        await drainTeardown(store)
    }

    func testResizeSmallerOpensNewSpawnAndLeavesOriginal() async {
        let store = makeStore()
        let first = await store.createGroup(allocations: [
            SpawnAgentAllocation(agent: .claude, count: 4),
        ])
        guard let original = first.group else { return XCTFail("expected a group") }

        let ok = await store.resizeGroup(groupId: original.id, to: 2)
        XCTAssertTrue(ok)
        XCTAssertEqual(store.groups.count, 2, "a smaller target opens a new spawn")
        XCTAssertEqual(store.group(id: original.id)?.tiles.count, 4,
                       "the original spawn's live agents are untouched")
        guard let newGroup = store.groups.first(where: { $0.id != original.id }) else {
            return XCTFail("expected a second group")
        }
        XCTAssertEqual(newGroup.name, "Spawn 2")
        XCTAssertEqual(newGroup.tiles.count, 2)
        XCTAssertEqual(store.selectedGroupId, newGroup.id, "selection follows the new spawn")
        store.closeGroup(id: original.id)
        store.closeGroup(id: newGroup.id)
        await drainTeardown(store)
    }

    func testResizeEqualIsNoOp() async {
        let store = makeStore()
        let result = await store.createGroup(allocations: [
            SpawnAgentAllocation(agent: .claude, count: 2),
        ])
        guard let group = result.group else { return XCTFail("expected a group") }
        let ok = await store.resizeGroup(groupId: group.id, to: 2)
        XCTAssertTrue(ok)
        XCTAssertEqual(store.groups.count, 1)
        XCTAssertEqual(store.group(id: group.id)?.tiles.count, 2)
        store.closeGroup(id: group.id)
        await drainTeardown(store)
    }

    func testResizeSmallerPreservesDominantAgentMix() async {
        let store = makeStore()
        let first = await store.createGroup(allocations: [
            SpawnAgentAllocation(agent: .claude, count: 2),
            SpawnAgentAllocation(agent: .codex, count: 2),
        ])
        guard let original = first.group else { return XCTFail("expected a group") }

        // Shrink 2 Claude · 2 Codex → 2: rebalanced trims from the bottom of
        // display order (codex after claude), so the new spawn keeps Claude.
        let ok = await store.resizeGroup(groupId: original.id, to: 2)
        XCTAssertTrue(ok)
        guard let newGroup = store.groups.first(where: { $0.id != original.id }) else {
            return XCTFail("expected a second group")
        }
        XCTAssertEqual(newGroup.tiles.map(\.agent), [.claude, .claude])
        store.closeGroup(id: original.id)
        store.closeGroup(id: newGroup.id)
        await drainTeardown(store)
    }

    func testResizeMissingGroupReturnsFalse() async {
        let store = makeStore()
        let ok = await store.resizeGroup(groupId: UUID(), to: 4)
        XCTAssertFalse(ok)
        await drainTeardown(store)
    }

    func testStaleExitDoesNotReinsertAfterClose() async {
        let store = makeStore()
        let result = await store.createGroup(allocations: [
            SpawnAgentAllocation(agent: .claude, count: 1),
        ])
        guard let group = result.group, let tile = group.tiles.first else {
            return XCTFail("expected a tile")
        }
        store.closeGroup(id: group.id)
        // Deterministic wait: poll until the kill actually lands (host no
        // longer running) so the exit event is GUARANTEED delivered before
        // the negative assertion — a fixed sleep can pass vacuously.
        var stillRunning = await tile.host.isRunning
        for _ in 0..<100 where stillRunning {
            try? await Task.sleep(nanoseconds: 50_000_000)
            stillRunning = await tile.host.isRunning
        }
        XCTAssertFalse(stillRunning, "kill never landed — cannot exercise the staleness guard")
        // One more beat for the onExit Task hop onto the main actor.
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(store.exitedTileIds.contains(tile.id))
        await drainTeardown(store)
    }

    // MARK: - opencode binary resolution (TUI, not the bundled serve helper)

    /// Spawn launches an interactive TUI; the app-bundled `Vendor/opencode`
    /// binary is a Bun `opencode serve` helper that renders nothing and exits
    /// as a TUI (the "OpenCode Go … exited" bug). The candidate list must lead
    /// with the official-installer path and never name a bundled/Vendor path.
    func testOpencodeRealInstallCandidatesPreferUserInstallNotBundle() {
        let candidates = SpawnModeStore.opencodeRealInstallCandidates(home: "/Users/test")
        XCTAssertEqual(candidates.first, "/Users/test/.opencode/bin/opencode")
        XCTAssertTrue(candidates.contains("/opt/homebrew/bin/opencode"))
        XCTAssertFalse(
            candidates.contains { $0.localizedCaseInsensitiveContains("Vendor") },
            "spawn TUI must never resolve to the app-bundled opencode serve helper"
        )
    }
}

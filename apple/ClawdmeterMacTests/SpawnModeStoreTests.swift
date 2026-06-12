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
}

import Foundation
import SwiftUI
import OSLog
import Darwin
import ClawdmeterShared

private let spawnLogger = Logger(subsystem: "com.clawdmeter.mac", category: "SpawnMode")

/// One terminal tile inside a spawn group: an agent CLI running interactively
/// in a direct PTY, cwd'd to the user's home directory.
struct SpawnTile: Identifiable {
    let id: UUID
    let agent: AgentKind
    let title: String
    /// Reference type (actor) — the PTY survives view teardown so collapsing
    /// or switching away from the grid never kills the agent process.
    let host: TerminalPtyHost
    /// Child pid captured at spawn so app-quit teardown can signal the
    /// process group synchronously (`applicationWillTerminate` can't await
    /// an actor hop before the process dies).
    let pid: pid_t
}

/// A named batch of spawn tiles ("Spawn 1", "Spawn 2", …) shown above
/// Projects in the Code sidebar.
struct SpawnGroup: Identifiable {
    let id: UUID
    let name: String
    let createdAt: Date
    var tiles: [SpawnTile]

    /// "4 Claude · 2 Codex" — sidebar subtitle, most-to-least like the grid.
    var agentSummary: String {
        var counts: [AgentKind: Int] = [:]
        var order: [AgentKind] = []
        for tile in tiles {
            if counts[tile.agent] == nil { order.append(tile.agent) }
            counts[tile.agent, default: 0] += 1
        }
        return order
            .map { "\(counts[$0] ?? 0) \(AgentKindUI.displayName(for: $0))" }
            .joined(separator: " · ")
    }
}

/// Per-agent availability for the spawn config page. Split so the row can
/// say WHY an agent is greyed out (not installed vs disabled in Settings).
struct SpawnAgentAvailability {
    let installed: Bool
    let enabled: Bool
    var isSpawnable: Bool { installed && enabled }
}

/// Outcome of a spawn batch: the group (nil when nothing launched) plus the
/// titles of slots that failed so the sheet can surface partial failures.
struct SpawnCreateResult {
    let group: SpawnGroup?
    let failedSlotTitles: [String]
}

/// Owns every spawn group's PTY tiles + the grid's selection/expansion state.
/// Process-wide singleton (like `TerminalPtyRegistry`) so PTYs outlive any
/// individual SwiftUI view: switching app tabs must not kill the agents.
@MainActor
final class SpawnModeStore: ObservableObject {
    static let shared = SpawnModeStore()

    @Published private(set) var groups: [SpawnGroup] = []
    /// Spawn group currently shown in the Code center pane. Mutually
    /// exclusive with the session/draft/terminal/document selections on
    /// `SessionsModel` — `SessionWorkspaceView` keeps the two in sync.
    @Published var selectedGroupId: UUID?
    /// Per-group typing target — the tile whose terminal owns the keyboard.
    @Published var selectedTileByGroup: [UUID: UUID] = [:]
    /// Per-group expanded tile (fills the center pane until compacted).
    @Published var expandedTileByGroup: [UUID: UUID] = [:]
    /// Tiles whose agent process has exited (terminal output stays visible).
    @Published var exitedTileIds: Set<UUID> = []

    private var nextSpawnNumber = 1
    /// Tiles mid-creation (handler registered, group not appended yet) —
    /// `markTileExited`'s staleness guard must not drop their exit events.
    private var pendingSpawnTileIds: Set<UUID> = []

    /// Test seam: overrides the per-agent launch argv so XCTest can seed
    /// groups with hermetic binaries (`/bin/cat`) instead of real agent CLIs.
    var launchArgvOverride: ((AgentKind) -> [String]?)?

    var selectedGroup: SpawnGroup? {
        guard let id = selectedGroupId else { return nil }
        return group(id: id)
    }

    func group(id: UUID) -> SpawnGroup? {
        groups.first(where: { $0.id == id })
    }

    /// Tiles whose agent process is still running. Both destructive
    /// close-spawn gates (grid header + sidebar context menu) key their
    /// confirm-or-close-immediately decision off this ONE definition.
    func liveTileCount(in group: SpawnGroup) -> Int {
        group.tiles.filter { !exitedTileIds.contains($0.id) }.count
    }

    func hasLiveTiles(in group: SpawnGroup) -> Bool {
        liveTileCount(in: group) > 0
    }

    // MARK: - Spawning

    /// Availability for the spawn config page. An agent is spawnable when
    /// its interactive CLI is on disk AND the provider is enabled in
    /// Settings → Providers (same gate the daemon's spawn path enforces).
    nonisolated static func agentAvailability(_ agent: AgentKind) -> SpawnAgentAvailability {
        SpawnAgentAvailability(
            installed: binaryPath(for: agent) != nil,
            enabled: ProviderEnablement.isEnabled(agent)
        )
    }

    /// Open a new spawn group from the chosen allocation. Tiles launch
    /// most-allocated-first (SpawnPlan ordering), each one an interactive
    /// agent CLI in the home directory.
    func createGroup(allocations: [SpawnAgentAllocation]) async -> SpawnCreateResult {
        let slots = SpawnPlan.slots(for: allocations)
        guard !slots.isEmpty else { return SpawnCreateResult(group: nil, failedSlotTitles: []) }
        // Real user home, not the sandbox container — matches every other
        // provider-state path in the codebase (ClawdmeterRealHome doc).
        let home = ClawdmeterRealHome.path()
        var tiles: [SpawnTile] = []
        var failedSlotTitles: [String] = []
        for slot in slots {
            // When the test seam is installed, its nil means "no binary" —
            // never fall through to the real PATH lookup.
            let resolvedArgv: [String]?
            if let launchArgvOverride {
                resolvedArgv = launchArgvOverride(slot.agent)
            } else {
                resolvedArgv = Self.launchArgv(for: slot.agent)
            }
            guard let argv = resolvedArgv else {
                spawnLogger.error("spawn slot \(slot.title, privacy: .public) skipped: no binary for \(slot.agent.rawValue, privacy: .public)")
                failedSlotTitles.append(slot.title)
                continue
            }
            let tileId = UUID()
            let host = TerminalPtyHost(
                title: slot.title,
                argv: argv,
                cwd: home,
                env: Self.launchEnv(for: slot.agent)
            )
            let pid: pid_t
            do {
                pid = try await host.start()
            } catch {
                spawnLogger.error("spawn slot \(slot.title, privacy: .public) failed to start: \(error.localizedDescription, privacy: .public)")
                failedSlotTitles.append(slot.title)
                continue
            }
            // Pending window: between handler registration and the group
            // append below, an exit must not be dropped by the staleness
            // guard in markTileExited.
            pendingSpawnTileIds.insert(tileId)
            await host.setOnExit { [weak self] _ in
                Task { @MainActor in self?.markTileExited(tileId) }
            }
            // setOnExit registers AFTER start(); a child that died in that
            // window already fired (and dropped) its onExit. Catch up here
            // so a fast-failing CLI doesn't render as a live tile forever.
            if await !host.isRunning {
                exitedTileIds.insert(tileId)
            }
            tiles.append(SpawnTile(id: tileId, agent: slot.agent, title: slot.title, host: host, pid: pid))
        }
        defer { pendingSpawnTileIds.subtract(tiles.map(\.id)) }
        guard !tiles.isEmpty else {
            return SpawnCreateResult(group: nil, failedSlotTitles: failedSlotTitles)
        }
        let group = SpawnGroup(
            id: UUID(),
            name: "Spawn \(nextSpawnNumber)",
            createdAt: Date(),
            tiles: tiles
        )
        nextSpawnNumber += 1
        groups.append(group)
        selectedGroupId = group.id
        selectedTileByGroup[group.id] = tiles.first?.id
        return SpawnCreateResult(group: group, failedSlotTitles: failedSlotTitles)
    }

    /// Guarded: a tile closed (and killed) before its natural exit lands
    /// must not re-insert a stale id — `exitedTileIds` would grow forever.
    /// Tiles still mid-creation count as live (`pendingSpawnTileIds`).
    private func markTileExited(_ tileId: UUID) {
        guard pendingSpawnTileIds.contains(tileId)
                || groups.contains(where: { $0.tiles.contains(where: { $0.id == tileId }) })
        else { return }
        exitedTileIds.insert(tileId)
    }

    // MARK: - Lifecycle

    func closeGroup(id: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        let group = groups.remove(at: index)
        selectedTileByGroup[id] = nil
        expandedTileByGroup[id] = nil
        if selectedGroupId == id { selectedGroupId = nil }
        let hosts = group.tiles.map(\.host)
        for tile in group.tiles {
            exitedTileIds.remove(tile.id)
        }
        // One serialized teardown task: TerminalPtyHost.kill blocks its
        // executor thread in PtyProcessTerminator's wait loops (~1s worst
        // case). Eight concurrent kills would pin eight cooperative-pool
        // threads; sequential keeps it to one.
        Task.detached(priority: .utility) {
            for host in hosts {
                await host.kill()
            }
        }
    }

    func closeTile(groupId: UUID, tileId: UUID) {
        guard let groupIndex = groups.firstIndex(where: { $0.id == groupId }),
              let tileIndex = groups[groupIndex].tiles.firstIndex(where: { $0.id == tileId })
        else { return }
        let tile = groups[groupIndex].tiles.remove(at: tileIndex)
        exitedTileIds.remove(tile.id)
        let host = tile.host
        Task.detached(priority: .utility) { await host.kill() }
        if expandedTileByGroup[groupId] == tileId {
            expandedTileByGroup[groupId] = nil
        }
        if selectedTileByGroup[groupId] == tileId {
            selectedTileByGroup[groupId] = groups[groupIndex].tiles.first?.id
        }
        if groups[groupIndex].tiles.isEmpty {
            closeGroup(id: groupId)
        }
    }

    /// Called from `applicationWillTerminate`: signal every LIVE spawn
    /// child's process group synchronously so Cmd+Q doesn't orphan agents
    /// that ignore the SIGHUP from the dying PTY master. No waits/reaps —
    /// the process is exiting; signals are best-effort and instantaneous.
    ///
    /// Exited tiles are skipped: their pids were already reaped by the
    /// host's exit watcher, so signaling them risks hitting a RECYCLED
    /// pid belonging to an unrelated process. `exitedTileIds` is the
    /// synchronous liveness proxy this non-async context can read.
    /// SIGKILL follows SIGTERM because there is no later escalation
    /// opportunity — the app is gone in milliseconds.
    func terminateAllForAppQuit() {
        for group in groups {
            for tile in group.tiles where tile.pid > 0 && !exitedTileIds.contains(tile.id) {
                _ = Darwin.kill(-tile.pid, SIGHUP)
                _ = Darwin.kill(tile.pid, SIGHUP)
                _ = Darwin.kill(-tile.pid, SIGTERM)
                _ = Darwin.kill(tile.pid, SIGTERM)
                _ = Darwin.kill(-tile.pid, SIGKILL)
                _ = Darwin.kill(tile.pid, SIGKILL)
            }
        }
    }

    // MARK: - Selection + expansion

    func selectTile(groupId: UUID, tileId: UUID) {
        guard selectedTileByGroup[groupId] != tileId else { return }
        selectedTileByGroup[groupId] = tileId
    }

    /// Expand a tile to fill the center pane; expanding again (or the
    /// compact button) sends it back into the grid.
    func toggleExpanded(groupId: UUID, tileId: UUID) {
        if expandedTileByGroup[groupId] == tileId {
            expandedTileByGroup[groupId] = nil
        } else {
            expandedTileByGroup[groupId] = tileId
            selectedTileByGroup[groupId] = tileId
        }
    }

    // MARK: - Launch plumbing

    /// Interactive CLI argv per agent. Plain TUI invocations — the user
    /// types into the agent directly, so no permission-skip flags here.
    nonisolated static func launchArgv(for agent: AgentKind) -> [String]? {
        guard let binary = binaryPath(for: agent) else { return nil }
        return [binary]
    }

    nonisolated static func binaryPath(for agent: AgentKind) -> String? {
        switch agent {
        case .claude:   return ShellRunner.locateBinary("claude")
        case .codex:    return ShellRunner.locateBinary("codex")
        case .cursor:   return AgentSpawner.cursorBinaryPath()
        case .gemini:   return ShellRunner.locateBinary("gemini")
        case .opencode: return ShellRunner.locateBinary("opencode")
        case .grok:     return ShellRunner.locateBinary("grok")
        case .unknown:  return nil
        }
    }

    /// Claude needs the sanitized subscription-rail env (`claudePtyEnv`);
    /// everything else just needs the PATH merge so a launchd-thin GUI PATH
    /// can still find node/rg/the CLI's own helpers.
    nonisolated static func launchEnv(for agent: AgentKind) -> [String: String] {
        if agent == .claude {
            return AgentSpawner.claudePtyEnv()
        }
        return SpawnPathResolver.merged(into: ProcessInfo.processInfo.environment)
    }
}

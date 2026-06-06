import Foundation
import ClawdmeterShared
import OSLog
import os.signpost

private let repoIndexLogger = Logger(subsystem: "com.clawdmeter.mac", category: "RepoIndex")

/// Builds and maintains the repo list shown in the Code workspace sidebar.
///
/// The index is intentionally limited to Continuum-managed workspaces. It no
/// longer scans Claude/Codex session history or arbitrary scan roots, so
/// sessions not initiated by Continuum do not surface in Code navigation.
public actor RepoIndex {

    /// Current cached snapshot. The view layer reads this synchronously.
    public private(set) var latestSnapshot: [AgentRepo] = []

    /// UserDefaults key for configured roots. These roots remain part of the
    /// workspace creation allow-list, but RepoIndex does not scan them for
    /// sessions or repos.
    public static let scanRootsKey = "clawdmeter.sessions.scanRoots"

    /// Track the most-recent refresh task so callers can `await` it.
    private var refreshTask: Task<[AgentRepo], Never>?

    /// Returns the current `WorkspaceStore.workspaces` snapshot. Defaults to
    /// `{ [] }` so tests and back-compat call sites can instantiate RepoIndex
    /// without wiring a workspace store.
    nonisolated let workspaceSnapshotProvider: @Sendable () async -> [CodeWorkspaceRecord]

    public init(
        workspaceSnapshotProvider: @escaping @Sendable () async -> [CodeWorkspaceRecord] = { [] }
    ) {
        self.workspaceSnapshotProvider = workspaceSnapshotProvider
    }

    // MARK: - Public API

    /// Returns the current snapshot. Always cheap (in-memory).
    public func snapshot() -> [AgentRepo] {
        latestSnapshot
    }

    /// Trigger a background refresh. If one is already in flight, returns
    /// the existing task's result (debounces concurrent refresh requests).
    @discardableResult
    public func refresh() async -> [AgentRepo] {
        if let task = refreshTask, !task.isCancelled {
            return await task.value
        }
        let task = Task<[AgentRepo], Never> { @Sendable in
            await self.buildSnapshot()
        }
        refreshTask = task
        let result = await task.value
        latestSnapshot = result
        refreshTask = nil
        return result
    }

    /// Start a periodic refresh loop. Every `interval` seconds, rebuild
    /// the snapshot. Caller is responsible for managing the returned Task
    /// (cancel on shutdown).
    public func startPeriodicRefresh(interval: TimeInterval = 60) -> Task<Void, Never> {
        Task { [weak self] in
            await self?.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { break }
                await self?.refresh()
            }
        }
    }

    // MARK: - Snapshot build

    private nonisolated func buildSnapshot() async -> [AgentRepo] {
        let signpostID = OSSignpostID(log: chatPerfLog)
        os_signpost(.begin, log: chatPerfLog, name: "repo-refresh",
                    signpostID: signpostID)
        defer {
            os_signpost(.end, log: chatPerfLog, name: "repo-refresh",
                        signpostID: signpostID)
        }

        let workspaces = await workspaceSnapshotProvider()
        var reposByKey: [String: AgentRepo] = [:]

        for workspace in workspaces {
            let key = RepoIdentity.normalize(workspace.repoRoot)
            let displayName = workspace.repoDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
            reposByKey[key] = AgentRepo(
                key: key,
                displayName: displayName.isEmpty ? RepoIdentity.displayName(for: key) : displayName,
                hasActiveSessions: false,
                liveSessionCount: 0,
                recentSessions: []
            )
        }

        let repos = reposByKey.values.sorted {
            if $0.displayName != $1.displayName {
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
            return $0.key < $1.key
        }
        repoIndexLogger.info("Snapshot built: \(repos.count) managed repos; external session discovery disabled")
        return repos
    }
}

import Foundation

/// Line deltas for a worktree branch relative to the repo's default branch,
/// plus any current staged/unstaged edits on top of HEAD.
struct WorktreeDiffStat: Equatable, Sendable {
    var additions: Int
    var deletions: Int

    var isEmpty: Bool { additions == 0 && deletions == 0 }

    mutating func add(_ other: WorktreeDiffStat) {
        additions += other.additions
        deletions += other.deletions
    }
}

enum WorktreeDiffFormatting {
    /// Compact sidebar counts — mirrors Conductor's `+11k` style.
    static func compactCount(_ value: Int) -> String {
        guard value > 0 else { return "0" }
        if value >= 10_000 { return "\(value / 1_000)k" }
        if value >= 1_000 {
            let thousands = Double(value) / 1_000.0
            if thousands >= 10 { return "\(Int(thousands.rounded()))k" }
            let formatted = String(format: "%.1fk", thousands)
            return formatted.hasSuffix(".0k")
                ? String(formatted.dropLast(3)) + "k"
                : formatted
        }
        return "\(value)"
    }
}

/// Polls git numstats for visible sidebar worktrees.
@MainActor
final class WorktreeDiffTracker: ObservableObject {
    @Published private(set) var stats: [String: WorktreeDiffStat] = [:]

    private let runner: ShellRunning
    private let gitLocator: @Sendable () -> String?
    private var refreshTask: Task<Void, Never>?
    private var isRefreshing = false
    private var pendingRefreshPaths: [String]?

    init(
        runner: ShellRunning = ShellRunner.shared,
        gitLocator: @escaping @Sendable () -> String? = { ShellRunner.locateBinary("git") }
    ) {
        self.runner = runner
        self.gitLocator = gitLocator
    }

    func stat(for path: String) -> WorktreeDiffStat? {
        stats[path]
    }

    /// Coalesce bursty sidebar invalidations (expand/collapse, search) into one git sweep.
    func scheduleRefresh(paths: [String]) {
        let unique = Array(Set(paths)).sorted()
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self, !Task.isCancelled else { return }
            await self.refresh(paths: unique)
        }
    }

    func refresh(paths: [String]) async {
        guard let git = gitLocator() else { return }
        let unique = Array(Set(paths))
        if isRefreshing {
            pendingRefreshPaths = unique
            return
        }
        guard !unique.isEmpty else {
            stats = [:]
            return
        }

        isRefreshing = true
        var next: [String: WorktreeDiffStat] = [:]
        next.reserveCapacity(unique.count)
        await withTaskGroup(of: (String, WorktreeDiffStat?).self) { group in
            for path in unique {
                group.addTask {
                    let stat = await Self.loadStat(cwd: path, git: git, runner: self.runner)
                    return (path, stat)
                }
            }
            for await (path, stat) in group {
                if let stat, !stat.isEmpty {
                    next[path] = stat
                }
            }
        }
        isRefreshing = false
        if stats != next {
            stats = next
        }
        if let pendingRefreshPaths {
            self.pendingRefreshPaths = nil
            scheduleRefresh(paths: pendingRefreshPaths)
        }
    }

    nonisolated private static func loadStat(
        cwd: String,
        git: String,
        runner: ShellRunning
    ) async -> WorktreeDiffStat? {
        guard await refExists(git: git, cwd: cwd, ref: "HEAD", runner: runner) else {
            return nil
        }
        var total = WorktreeDiffStat(additions: 0, deletions: 0)
        var foundBase = false
        for base in ["main", "master", "origin/main", "origin/master"] {
            guard await refExists(git: git, cwd: cwd, ref: base, runner: runner) else { continue }
            if let stat = await numstatTotal(
                git: git,
                cwd: cwd,
                arguments: ["-C", cwd, "diff", "--numstat", "\(base)...HEAD"],
                runner: runner
            ) {
                total.add(stat)
                foundBase = true
                break
            }
        }
        if foundBase {
            // Supplement the committed branch delta with any uncommitted edits
            // on top of HEAD. `--cached` (index vs HEAD) and the plain numstat
            // (working tree vs index) are disjoint, so summing them yields the
            // full working-tree-vs-HEAD delta without overlap.
            if let staged = await numstatTotal(
                git: git,
                cwd: cwd,
                arguments: ["-C", cwd, "diff", "--cached", "--numstat"],
                runner: runner
            ) {
                total.add(staged)
            }
            if let unstaged = await numstatTotal(
                git: git,
                cwd: cwd,
                arguments: ["-C", cwd, "diff", "--numstat"],
                runner: runner
            ) {
                total.add(unstaged)
            }
        } else if let headStat = await numstatTotal(
            git: git,
            cwd: cwd,
            // No default branch to diff against; `git diff HEAD` already covers
            // both staged and unstaged edits, so it is the complete total on its
            // own. Adding `--cached`/`--numstat` here would double-count.
            arguments: ["-C", cwd, "diff", "--numstat", "HEAD"],
            runner: runner
        ) {
            total.add(headStat)
        }
        return total
    }

    nonisolated private static func refExists(
        git: String,
        cwd: String,
        ref: String,
        runner: ShellRunning
    ) async -> Bool {
        let result = try? await runner.run(
            executable: git,
            arguments: ["-C", cwd, "rev-parse", "--verify", ref],
            cwd: nil,
            environment: nil,
            timeout: 5
        )
        return result?.exitStatus == 0
    }

    nonisolated private static func numstatTotal(
        git: String,
        cwd: String,
        arguments: [String],
        runner: ShellRunning
    ) async -> WorktreeDiffStat? {
        let result = try? await runner.run(
            executable: git,
            arguments: arguments,
            cwd: nil,
            environment: nil,
            timeout: 10
        )
        guard let result, result.exitStatus == 0 else { return nil }
        var additions = 0
        var deletions = 0
        for line in result.stdoutString.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard parts.count == 3 else { continue }
            additions += Int(parts[0]) ?? 0
            deletions += Int(parts[1]) ?? 0
        }
        return WorktreeDiffStat(additions: additions, deletions: deletions)
    }
}

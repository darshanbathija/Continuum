import Foundation

/// Line deltas for a worktree branch relative to the repo's default branch.
struct WorktreeDiffStat: Equatable, Sendable {
    var additions: Int
    var deletions: Int

    var isEmpty: Bool { additions == 0 && deletions == 0 }
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

/// Polls `git diff --numstat <base>...HEAD` for visible sidebar worktrees.
@MainActor
final class WorktreeDiffTracker: ObservableObject {
    @Published private(set) var stats: [String: WorktreeDiffStat] = [:]

    private let runner: ShellRunning
    private let gitLocator: @Sendable () -> String?
    private var refreshTask: Task<Void, Never>?

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
        guard !unique.isEmpty else {
            stats = [:]
            return
        }

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
        stats = next
    }

    nonisolated private static func loadStat(
        cwd: String,
        git: String,
        runner: ShellRunning
    ) async -> WorktreeDiffStat? {
        guard await refExists(git: git, cwd: cwd, ref: "HEAD", runner: runner) else {
            return nil
        }
        for base in ["main", "master", "origin/main", "origin/master"] {
            guard await refExists(git: git, cwd: cwd, ref: base, runner: runner) else { continue }
            if let stat = await numstatTotal(
                git: git,
                cwd: cwd,
                arguments: ["-C", cwd, "diff", "--numstat", "\(base)...HEAD"],
                runner: runner
            ) {
                return stat
            }
        }
        return await numstatTotal(
            git: git,
            cwd: cwd,
            arguments: ["-C", cwd, "diff", "--numstat", "HEAD"],
            runner: runner
        )
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

import Foundation

/// One row from a gstack `tasks-*.jsonl` artifact (CEO / eng / design review
/// task lists). Each line of the JSONL is one `PlanItem`.
///
/// gstack writes one JSON object per line; we decode them lazily without
/// holding the full file in memory beyond the parsed array, which is fine
/// for the ~30-item plans we ship today.
struct PlanItem: Identifiable, Hashable, Codable {
    let id: String
    let priority: String
    let component: String
    let files: [String]
    let effortHuman: String
    let effortCC: String
    let title: String
    let sourceFinding: String?

    enum CodingKeys: String, CodingKey {
        case id, priority, component, files, title
        case effortHuman = "effort_human"
        case effortCC = "effort_cc"
        case sourceFinding = "source_finding"
    }
}

/// Resolved spawn target for a `PlanItem` — pairs the plan row with the
/// already-cut worktree it should run in. Built up front by
/// `PlanAssignmentRegistry.defaults`; the spawn sheet renders one row per
/// `(item, assignment)` pair so the user knows exactly where each session
/// will land before clicking Spawn.
struct PlanAssignment: Hashable {
    /// PR id from the plan (matches `PlanItem.id`).
    let planItemId: String
    /// Feature branch, already created via `git worktree add -b`.
    let branch: String
    /// Absolute path to the worktree on disk.
    let worktreePath: String
    /// Base branch the worktree was cut off (for the agent's PR command).
    let baseBranch: String
}

/// One row in the spawn sheet — pairs an assignment with the JSONL row
/// that describes the work (or a synthesized stub when the assignment
/// doesn't exist in the plan artifact, as happens for wire follow-ups
/// that were planned after the CEO review JSONL was written).
struct PlanQueueRow: Identifiable, Hashable {
    let assignment: PlanAssignment
    let item: PlanItem

    var id: String { assignment.planItemId }
}

/// In-memory registry of the rows the sheet should render. `rows` is
/// the source of truth for what "Continue plan" can spawn this session
/// — one row per pre-cut worktree.
struct PlanQueue {
    let rows: [PlanQueueRow]
}

/// Resolves the dev-side Clawdmeter checkout the spawn sheet should
/// dispatch into. Reads from:
///   1. `UserDefaults` key `plan.repoRoot` (set this when your checkout
///      lives somewhere other than `~/Downloads/CC Watch/Clawdmeter`)
///   2. otherwise the default path under `~/Downloads/CC Watch/`
///
/// Kept as a tiny standalone helper so tests can swap in a tmp dir
/// without touching MacRootView.
enum PlanRepoRoot {
    static let userDefaultsKey = "plan.repoRoot"
    static let defaultsRelative = "Downloads/CC Watch/Clawdmeter"

    static func resolved(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                        defaults: UserDefaults = .standard) -> URL {
        if let override = defaults.string(forKey: userDefaultsKey), !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return home.appendingPathComponent(defaultsRelative, isDirectory: true)
    }
}

enum PlanQueueLoader {
    /// Default JSONL location written by `/plan-ceo-review`. Relative
    /// to `$HOME` so we don't bake the user's account name into the bundle.
    static let defaultRelativePath = ".gstack/projects/darshanbathija-cc-watch"

    /// Newest `tasks-*.jsonl` under `~/.gstack/projects/<slug>/`.
    /// Returns `nil` when the gstack project directory is missing, which
    /// is the case on machines that haven't run a plan review yet — the
    /// sheet then surfaces an empty-state explainer instead of crashing.
    static func defaultJSONLURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let dir = home.appendingPathComponent(defaultRelativePath, isDirectory: true)
        guard let contents = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return nil
        }
        let matches = contents.filter { url in
            let name = url.lastPathComponent
            return name.hasPrefix("tasks-") && name.hasSuffix(".jsonl")
        }
        return matches
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return l > r
            }
            .first
    }

    /// Decode every JSON object line in `url` into a `PlanItem`.
    /// Lines that fail to decode are skipped — gstack's JSONL artifacts
    /// occasionally include header rows or future fields we don't yet
    /// model, and the right behavior is to drop them rather than fail
    /// the whole sheet.
    static func loadItems(from url: URL) throws -> [PlanItem] {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line -> PlanItem? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return nil }
                guard let lineData = trimmed.data(using: .utf8) else { return nil }
                return try? decoder.decode(PlanItem.self, from: lineData)
            }
    }

    /// Build the spawn-sheet queue: assignments are the source of truth
    /// (every cut worktree produces one row); JSONL items enrich them
    /// with human-readable title / files / acceptance. When an
    /// assignment has no matching JSONL row (e.g. wire follow-ups that
    /// post-date the CEO review), we synthesize a stub PlanItem from
    /// the branch name so the row still renders.
    static func load(
        repoRoot: URL,
        jsonlURL: URL? = nil
    ) -> PlanQueue {
        let url = jsonlURL ?? defaultJSONLURL()
        let items: [PlanItem]
        if let url, FileManager.default.fileExists(atPath: url.path) {
            items = (try? loadItems(from: url)) ?? []
        } else {
            items = []
        }
        let byId = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let assignments = PlanAssignmentRegistry.defaults(repoRoot: repoRoot)
        let rows = assignments.values
            .sorted { $0.planItemId < $1.planItemId }
            .map { assignment -> PlanQueueRow in
                let item = byId[assignment.planItemId] ?? PlanItem(
                    id: assignment.planItemId,
                    priority: "P2",
                    component: "follow-up",
                    files: [],
                    effortHuman: "—",
                    effortCC: "—",
                    title: assignment.branch,
                    sourceFinding: nil
                )
                return PlanQueueRow(assignment: assignment, item: item)
            }
        return PlanQueue(rows: rows)
    }
}

/// Static map of plan items → worktree paths. This is intentionally
/// hardcoded — the worktrees were cut deliberately for this session, and
/// the registry mirrors that decision so the sheet always knows where
/// each spawn should land. Update when you cut more worktrees.
enum PlanAssignmentRegistry {
    static func defaults(repoRoot: URL) -> [String: PlanAssignment] {
        // The 10 worktrees pre-cut for the next wave of the plan.
        // `worktreesRoot` is the sibling `Clawdmeter-worktrees/` directory
        // — every `git worktree add` in this session placed paths under
        // it relative to the primary `Clawdmeter/` checkout.
        let worktreesRoot = repoRoot
            .deletingLastPathComponent()
            .appendingPathComponent("Clawdmeter-worktrees", isDirectory: true)

        let rows: [(id: String, branch: String, slug: String, base: String)] = [
            ("A5",  "perf/a5-slice-chatstore-publishing", "a5-slice",             "main"),
            ("A6",  "perf/a6-split-workspace-view",       "a6-split-workspace",   "main"),
            ("A11", "perf/a11-sidebar-projection-cache",  "a11-sidebar-cache",    "main"),
            ("A12", "perf/a12-diff-workbench-virtual",    "a12-diff-virtual",     "main"),
            ("A13", "perf/a13-optimistic-composer-ui",    "a13-optimistic",       "main"),
            ("B1",  "perf/b1-incremental-jsonl-ingest",   "b1-jsonl-incremental", "main"),
            ("F2",  "feat/f2-orchestration-event-store",  "f2-event-store",       "feat/f1-foundation-provider-runtime-event"),
            ("E2",  "feat/e2-relay-worker",               "e2-relay-worker",      "feat/e0-worker-infra-prep"),
            ("E5",  "feat/e5-apns-gateway-worker",        "e5-apns-gateway",      "feat/e0-worker-infra-prep"),
            ("F1a-wire", "feat/f1a-wire-claude-adapter",  "f1a-wire",             "feat/f1a-claude-adapter"),
        ]

        var map: [String: PlanAssignment] = [:]
        for row in rows {
            let path = worktreesRoot.appendingPathComponent(row.slug, isDirectory: true).path
            map[row.id] = PlanAssignment(
                planItemId: row.id,
                branch: row.branch,
                worktreePath: path,
                baseBranch: row.base
            )
        }
        return map
    }
}

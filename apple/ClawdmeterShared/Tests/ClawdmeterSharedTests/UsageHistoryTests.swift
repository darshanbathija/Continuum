import XCTest
@testable import ClawdmeterShared

final class UsageHistoryTests: XCTestCase {

    // MARK: - ClaudeUsageParser

    func test_claudeParse_validLine() {
        let line = """
        {"message":{"id":"msg_1","model":"claude-sonnet-4-5","usage":{"input_tokens":100,"output_tokens":50}},"timestamp":"2026-05-15T10:00:00Z","requestId":"req_1","cwd":"/Users/x/foo"}
        """
        let data = line.data(using: .utf8)!
        let record = ClaudeUsageParser.parse(line: data)
        XCTAssertNotNil(record)
        XCTAssertEqual(record?.provider, .claude)
        XCTAssertEqual(record?.tokens.inputTokens, 100)
        XCTAssertEqual(record?.tokens.outputTokens, 50)
        // `/Users/x/foo` doesn't exist on disk, so canonical resolution
        // can't find a `.git` and buckets it under `.other`.
        XCTAssertEqual(record?.repo, RepoKey.other)
        XCTAssertEqual(record?.dedupKey, "msg_1:req_1")
    }

    func test_claudeParse_missingUsageReturnsNil() {
        let line = """
        {"message":{"id":"msg_1"},"timestamp":"2026-05-15T10:00:00Z"}
        """
        XCTAssertNil(ClaudeUsageParser.parse(line: line.data(using: .utf8)!))
    }

    func test_claudeParse_zeroTokensReturnsNil() {
        let line = """
        {"message":{"id":"msg_1","usage":{"input_tokens":0,"output_tokens":0}},"timestamp":"2026-05-15T10:00:00Z"}
        """
        XCTAssertNil(ClaudeUsageParser.parse(line: line.data(using: .utf8)!))
    }

    func test_claudeParse_missingCwd() {
        let line = """
        {"message":{"id":"msg_1","model":"claude-sonnet-4-5","usage":{"input_tokens":100,"output_tokens":50}},"timestamp":"2026-05-15T10:00:00Z","requestId":"req_1"}
        """
        let record = ClaudeUsageParser.parse(line: line.data(using: .utf8)!)
        XCTAssertNotNil(record)
        XCTAssertNil(record?.repo, "Missing cwd → repo: nil; aggregator buckets under '(unknown)'")
    }

    // MARK: - CodexUsageParser

    func test_codexParse_cumulativeDeltas() throws {
        let cwd = "/Users/x/myrepo"
        let lines = [
            #"{"timestamp":"2026-05-15T10:00:00Z","type":"session_meta","payload":{"cwd":"\#(cwd)"}}"#,
            #"{"timestamp":"2026-05-15T10:00:01Z","type":"turn_context","payload":{"model":"gpt-5-codex","cwd":"\#(cwd)"}}"#,
            #"{"timestamp":"2026-05-15T10:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":0,"output_tokens":500,"reasoning_output_tokens":0,"total_tokens":1500}}}}"#,
            #"{"timestamp":"2026-05-15T10:02:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":3000,"cached_input_tokens":500,"output_tokens":1500,"reasoning_output_tokens":0,"total_tokens":4500}}}}"#,
        ]
        let url = try writeTempFile(name: "rollout-test1.jsonl", lines: lines)
        defer { try? FileManager.default.removeItem(at: url) }

        let records = try CodexUsageParser.parse(file: url)
        XCTAssertEqual(records.count, 2)

        // First record: delta-from-zero = the first cumulative.
        // input = 1000 - 0 (cached) = 1000, cached = 0, output = 500.
        XCTAssertEqual(records[0].tokens.inputTokens, 1000)
        XCTAssertEqual(records[0].tokens.outputTokens, 500)
        XCTAssertEqual(records[0].tokens.cacheReadTokens, 0)
        // Synthetic path with no .git on disk → bucketed under `.other`.
        XCTAssertEqual(records[0].repo, RepoKey.other)
        XCTAssertEqual(records[0].model, "gpt-5-codex")

        // Second record: delta from cumulative.
        // cumulative input total = 3000, cached = 500 → uncached = 2500
        // previous uncached input = 1000 → delta = 1500
        // cumulative output = 1500 → delta = 1000
        // delta cached = 500
        XCTAssertEqual(records[1].tokens.inputTokens, 1500)
        XCTAssertEqual(records[1].tokens.outputTokens, 1000)
        XCTAssertEqual(records[1].tokens.cacheReadTokens, 500)
    }

    func test_codexParse_nonMonotonicDropTreatedAsBaseline() throws {
        // Simulate a session reset within one file: the second token_count
        // is LOWER than the first. The parser should NOT emit a negative
        // delta; it should treat the new cumulative as a fresh baseline.
        let lines = [
            #"{"timestamp":"2026-05-15T10:00:00Z","type":"session_meta","payload":{"cwd":"/r"}}"#,
            #"{"timestamp":"2026-05-15T10:00:01Z","type":"turn_context","payload":{"model":"gpt-5","cwd":"/r"}}"#,
            #"{"timestamp":"2026-05-15T10:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10000,"cached_input_tokens":0,"output_tokens":5000,"total_tokens":15000}}}}"#,
            #"{"timestamp":"2026-05-15T10:02:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":50,"total_tokens":150}}}}"#,
        ]
        let url = try writeTempFile(name: "rollout-reset.jsonl", lines: lines)
        defer { try? FileManager.default.removeItem(at: url) }

        let records = try CodexUsageParser.parse(file: url)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[1].tokens.totalTokens, 150, "Drop in cumulative should be treated as new baseline, not negative delta")
    }

    func test_codexParse_perFieldDropTreatedAsBaseline() throws {
        // A reset can show up as one counter dropping while total_tokens
        // still increases. The parser must not silently clamp the dropped
        // field to zero and keep subtracting from the stale baseline.
        let lines = [
            #"{"timestamp":"2026-05-15T10:00:00Z","type":"session_meta","payload":{"cwd":"/r"}}"#,
            #"{"timestamp":"2026-05-15T10:00:01Z","type":"turn_context","payload":{"model":"gpt-5","cwd":"/r"}}"#,
            #"{"timestamp":"2026-05-15T10:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":0,"output_tokens":900,"total_tokens":1900}}}}"#,
            #"{"timestamp":"2026-05-15T10:02:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1200,"cached_input_tokens":0,"output_tokens":100,"total_tokens":1300}}}}"#,
        ]
        let url = try writeTempFile(name: "rollout-field-reset.jsonl", lines: lines)
        defer { try? FileManager.default.removeItem(at: url) }

        let records = try CodexUsageParser.parse(file: url)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[1].tokens.inputTokens, 1200)
        XCTAssertEqual(records[1].tokens.outputTokens, 100)
    }

    func test_codexParse_missingSessionMeta() throws {
        // No session_meta → records have repo: nil → aggregator → "(unknown)"
        let lines = [
            #"{"timestamp":"2026-05-15T10:00:01Z","type":"turn_context","payload":{"model":"gpt-5"}}"#,
            #"{"timestamp":"2026-05-15T10:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":50,"total_tokens":150}}}}"#,
        ]
        let url = try writeTempFile(name: "rollout-no-meta.jsonl", lines: lines)
        defer { try? FileManager.default.removeItem(at: url) }

        let records = try CodexUsageParser.parse(file: url)
        XCTAssertEqual(records.count, 1)
        XCTAssertNil(records[0].repo)
    }

    // MARK: - RepoIdentity

    func test_repoIdentity_emptyReturnsUnknown() {
        XCTAssertEqual(RepoIdentity.normalize(""), RepoKey.unknown)
        XCTAssertEqual(RepoIdentity.normalize("   "), RepoKey.unknown)
    }

    func test_repoIdentity_nonExistentPathBucketsAsOther() {
        // Anything that isn't a real git repo on disk (and doesn't match a
        // Conductor/Claude-worktree pattern) collapses to the single
        // "(other)" bucket. The trim/expand step still runs internally but
        // is exercised end-to-end via the canonical-resolution tests below.
        XCTAssertEqual(RepoIdentity.normalize("/Users/x/repo/"), RepoKey.other)
        XCTAssertEqual(RepoIdentity.normalize("/"), RepoKey.other)
    }

    func test_repoIdentity_displayName() {
        XCTAssertEqual(RepoIdentity.displayName(for: "/Users/x/Downloads/CC Watch"), "CC Watch")
        XCTAssertEqual(RepoIdentity.displayName(for: RepoKey.unknown), "(unknown)")
    }

    // MARK: - Canonical repo resolution

    func test_canonicalRepo_regularGitDirectory() throws {
        RepoIdentity._resetCacheForTesting()
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repo = temp.appendingPathComponent("MyRepo")
        let subdir = repo.appendingPathComponent("apple").appendingPathComponent("ClawdmeterMac")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        // Make `.git` a directory (regular non-worktree checkout).
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        // Deep subdir → walks up to repo root.
        XCTAssertEqual(RepoIdentity.normalize(subdir.path), repo.path)
        // The repo root itself → returns itself.
        XCTAssertEqual(RepoIdentity.normalize(repo.path), repo.path)
        // Display name → last component.
        XCTAssertEqual(RepoIdentity.displayName(for: repo.path), "MyRepo")
    }

    func test_canonicalRepo_worktreeBucketsUnderMainRepo() throws {
        RepoIdentity._resetCacheForTesting()
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let mainRepo = temp.appendingPathComponent("Defx V3")
        let worktree = mainRepo.appendingPathComponent(".claude/worktrees/beautiful-cori")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: mainRepo.appendingPathComponent(".git"), withIntermediateDirectories: true)

        // Simulate a worktree: `.git` is a FILE pointing to the main worktree's gitdir.
        let mainGitWorktreesDir = mainRepo.appendingPathComponent(".git/worktrees/beautiful-cori")
        try FileManager.default.createDirectory(at: mainGitWorktreesDir, withIntermediateDirectories: true)
        let gitFilePath = worktree.appendingPathComponent(".git")
        let gitFileContents = "gitdir: \(mainGitWorktreesDir.path)\n"
        try gitFileContents.write(to: gitFilePath, atomically: true, encoding: .utf8)

        defer { try? FileManager.default.removeItem(at: temp) }

        // Worktree path → resolves back to main repo.
        XCTAssertEqual(RepoIdentity.normalize(worktree.path), mainRepo.path)
        // Display name comes from the main repo's basename, NOT the branch.
        XCTAssertEqual(RepoIdentity.displayName(for: RepoIdentity.normalize(worktree.path)), "Defx V3")
    }

    func test_canonicalRepo_conductorWorkspacesPattern() throws {
        RepoIdentity._resetCacheForTesting()
        // Mimics ~/conductor/repos/<Repo>/.git + ~/conductor/workspaces/<Repo>/<branch>
        // with a worktree .git pointing back.
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repoRoot = temp.appendingPathComponent("repos/nautilus-ui")
        let workspace = temp.appendingPathComponent("workspaces/nautilus-ui/honolulu")
        try FileManager.default.createDirectory(at: repoRoot.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let worktreesDir = repoRoot.appendingPathComponent(".git/worktrees/honolulu")
        try FileManager.default.createDirectory(at: worktreesDir, withIntermediateDirectories: true)
        try "gitdir: \(worktreesDir.path)\n".write(to: workspace.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: temp) }

        XCTAssertEqual(RepoIdentity.displayName(for: RepoIdentity.normalize(workspace.path)), "nautilus-ui")
    }

    func test_canonicalRepo_noGitBucketsAsOther() {
        // No `.git` anywhere → bucket under `RepoKey.other` so the by-repo
        // UI doesn't surface random non-repo paths (UUIDs, home dir,
        // Downloads, etc.) as if they were repos.
        RepoIdentity._resetCacheForTesting()
        let nonRepo = "/private/var/folders/no-such-path/\(UUID().uuidString)"
        XCTAssertEqual(RepoIdentity.normalize(nonRepo), RepoKey.other)
        XCTAssertEqual(RepoIdentity.displayName(for: RepoKey.other), "Other")
    }

    func test_canonicalRepo_deadConductorBranchCollapsesByPattern() {
        RepoIdentity._resetCacheForTesting()
        // No `.git` anywhere on disk for these paths. Two dead branches of
        // the same Conductor workspace should collapse to a single bucket.
        let a = "/Users/fake/conductor/workspaces/my-repo/beijing"
        let b = "/Users/fake/conductor/workspaces/my-repo/lisbon"
        let na = RepoIdentity.normalize(a)
        let nb = RepoIdentity.normalize(b)
        XCTAssertEqual(na, nb)
        XCTAssertEqual(RepoIdentity.displayName(for: na), "my-repo")
    }

    func test_canonicalRepo_liveConductorBranchResolvesToMainRepo() throws {
        RepoIdentity._resetCacheForTesting()
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let downloads = temp.appendingPathComponent("Downloads/my-repo")
        let workspacesDir = temp.appendingPathComponent("conductor/workspaces/my-repo")
        let aliveBranch = workspacesDir.appendingPathComponent("cambridge")
        let deadBranch = workspacesDir.appendingPathComponent("dead-branch")
        try FileManager.default.createDirectory(at: downloads.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: aliveBranch, withIntermediateDirectories: true)
        // Make a live worktree pointer.
        let worktreesDir = downloads.appendingPathComponent(".git/worktrees/cambridge")
        try FileManager.default.createDirectory(at: worktreesDir, withIntermediateDirectories: true)
        try "gitdir: \(worktreesDir.path)\n".write(to: aliveBranch.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: temp) }

        // Alive branch → resolves to the underlying main repo.
        let aliveNormalized = RepoIdentity.normalize(aliveBranch.path)
        XCTAssertEqual(aliveNormalized, downloads.path)
        // Dead branch (path doesn't exist on disk) → ALSO resolves to the
        // same underlying main repo because we walked an alive sibling's
        // .git pointer to discover it.
        let deadNormalized = RepoIdentity.normalize(deadBranch.path)
        XCTAssertEqual(deadNormalized, downloads.path)
    }

    func test_canonicalRepo_claudeWorktreePatternCollapses() {
        RepoIdentity._resetCacheForTesting()
        // .claude/worktrees pattern, no .git on disk → falls back to the
        // path prefix above .claude/worktrees so all worktrees share a bucket.
        let a = "/Users/fake/work/myrepo/.claude/worktrees/branch-a"
        let b = "/Users/fake/work/myrepo/.claude/worktrees/branch-b"
        XCTAssertEqual(RepoIdentity.normalize(a), "/Users/fake/work/myrepo")
        XCTAssertEqual(RepoIdentity.normalize(b), "/Users/fake/work/myrepo")
    }

    /// T30 — exercises the .claude/worktrees pattern with a real `.git`
    /// in the parent on disk. Sessions v2 spawns each session inside a
    /// `<repo>/.claude/worktrees/<slug-uuid>/` directory; the analytics
    /// pipeline must bucket those JSONLs back to the parent repo, not
    /// "(other)". The no-git fallback above guards the path-shape
    /// heuristic; this guards the canonical-resolution path the live
    /// daemon actually hits.
    func test_canonicalRepo_claudeWorktreeWithRealGitParent() throws {
        RepoIdentity._resetCacheForTesting()
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repo = temp.appendingPathComponent("axtior-platform")
        let worktree = repo
            .appendingPathComponent(".claude")
            .appendingPathComponent("worktrees")
            .appendingPathComponent("fix-auth-7f3a2c")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        // Real .git directory on the parent — the analytics layer
        // canonicalizes by walking up from a `cwd` until it finds one.
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temp) }

        // A session spawned inside the worktree dir should bucket to the
        // parent repo's canonical path. RepoKey is the canonicalized
        // absolute path; compare via standardizedFileURL to handle the
        // `/private/var` ↔ `/var` symlink macOS injects in temp paths.
        let normalized = RepoIdentity.normalize(worktree.path)
        let expected = repo.standardizedFileURL.path
        let normalizedStandardized = URL(fileURLWithPath: normalized).standardizedFileURL.path
        XCTAssertEqual(normalizedStandardized, expected,
                       "Worktree sessions must bucket to parent repo, not \(normalized)")
        // Sibling worktrees collapse to the same bucket.
        let sibling = repo
            .appendingPathComponent(".claude")
            .appendingPathComponent("worktrees")
            .appendingPathComponent("refactor-redis-9b1c")
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let siblingNormalized = URL(fileURLWithPath: RepoIdentity.normalize(sibling.path))
            .standardizedFileURL.path
        XCTAssertEqual(siblingNormalized, expected)
        // Display name comes from the repo's basename, not the worktree's.
        XCTAssertEqual(RepoIdentity.displayName(for: normalized), "axtior-platform")
    }

    func test_canonicalRepo_descendsToSoleGitChild() throws {
        // `wrapper/` has no `.git`, but contains exactly one git child
        // (`Clawdmeter/`). cwd=wrapper/ should bucket as `wrapper/Clawdmeter`
        // so sessions started from the parent and from the repo itself
        // collapse to the same bucket.
        RepoIdentity._resetCacheForTesting()
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let wrapper = temp.appendingPathComponent("CC Watch")
        let inner = wrapper.appendingPathComponent("Clawdmeter")
        try FileManager.default.createDirectory(at: inner.appendingPathComponent(".git"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        // From the wrapper → descends to the inner git child.
        XCTAssertEqual(RepoIdentity.normalize(wrapper.path), inner.path)
        // From inside the inner repo → walks up to the same git root.
        XCTAssertEqual(RepoIdentity.normalize(inner.path), inner.path)
        // Display name → the repo's basename, not the wrapper's.
        XCTAssertEqual(RepoIdentity.displayName(for: RepoIdentity.normalize(wrapper.path)), "Clawdmeter")
    }

    func test_canonicalRepo_descendOnlyWhenSoleGitChild() throws {
        // A wrapper containing TWO git children should NOT descend (ambiguous)
        // and the wrapper itself isn't a repo → falls through to `.other`.
        RepoIdentity._resetCacheForTesting()
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let wrapper = temp.appendingPathComponent("downloads")
        let a = wrapper.appendingPathComponent("repo-a")
        let b = wrapper.appendingPathComponent("repo-b")
        try FileManager.default.createDirectory(at: a.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b.appendingPathComponent(".git"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        XCTAssertEqual(RepoIdentity.normalize(wrapper.path), RepoKey.other)
    }

    // MARK: - Adaptive currency formatting

    func test_adaptivePrecisionFormatting() {
        XCTAssertEqual(AnalyticsCurrencyFormatter.format(0), "$0")
        XCTAssertEqual(AnalyticsCurrencyFormatter.format(Decimal(string: "4.31")!), "$4.31")
        // Below $0.01 → 4 decimals
        let small = AnalyticsCurrencyFormatter.format(Decimal(string: "0.0042")!)
        XCTAssertTrue(small.contains("0.0042"), "Got \(small)")
    }

    // MARK: - B2 mtime probe

    func test_mostRecentSourceMtime_emptyDirs_returnsNil() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let claudeDir = temp.appendingPathComponent("claude")
        let codexDir = temp.appendingPathComponent("codex")
        let geminiDir = temp.appendingPathComponent("gemini")
        for dir in [claudeDir, codexDir, geminiDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let loader = UsageHistoryLoader(
            claudeDir: claudeDir,
            codexDir: codexDir,
            geminiDir: geminiDir,
            agyDir: temp.appendingPathComponent("agy-missing"),
            opencodeDBURL: temp.appendingPathComponent("missing.db"),
            cacheURL: temp.appendingPathComponent("cache.json")
        )
        let mtime = await loader.mostRecentSourceMtime()
        XCTAssertNil(mtime, "Empty dirs → no files → no mtime")
    }

    func test_mostRecentSourceMtime_returnsLatestFileMtime() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let claudeDir = temp.appendingPathComponent("claude")
        let codexDir = temp.appendingPathComponent("codex")
        let geminiDir = temp.appendingPathComponent("gemini")
        for dir in [claudeDir, codexDir, geminiDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        // Drop one file in claudeDir at an old timestamp, one in codexDir
        // at a newer timestamp. The probe should return the newer.
        let oldFile = claudeDir.appendingPathComponent("old.jsonl")
        let newFile = codexDir.appendingPathComponent("new.jsonl")
        try "old".data(using: .utf8)!.write(to: oldFile)
        try "new".data(using: .utf8)!.write(to: newFile)

        let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
        let newDate = Date(timeIntervalSince1970: 1_715_000_000)
        try FileManager.default.setAttributes(
            [.modificationDate: oldDate], ofItemAtPath: oldFile.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: newDate], ofItemAtPath: newFile.path
        )

        let loader = UsageHistoryLoader(
            claudeDir: claudeDir,
            codexDir: codexDir,
            geminiDir: geminiDir,
            agyDir: temp.appendingPathComponent("agy-missing"),
            opencodeDBURL: temp.appendingPathComponent("missing.db"),
            cacheURL: temp.appendingPathComponent("cache.json")
        )
        let mtime = await loader.mostRecentSourceMtime()
        XCTAssertEqual(mtime, newDate, "Probe must return the latest mtime across all source dirs")
    }

    /// PR #137 review P0 #1: OpenCode runs SQLite in WAL mode. Commits
    /// land in `opencode.db-wal` first; the main `opencode.db` only
    /// advances on checkpoint. The probe must stat the WAL sidecar too,
    /// otherwise an SSE-driven refresh kicked off by .opencodeUsageRecorded
    /// short-circuits because the main file's mtime hasn't moved yet.
    func test_mostRecentSourceMtime_includesOpencodeWALSidecar() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let claudeDir = temp.appendingPathComponent("claude")
        let codexDir = temp.appendingPathComponent("codex")
        let geminiDir = temp.appendingPathComponent("gemini")
        for dir in [claudeDir, codexDir, geminiDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        // Main db at an old mtime; WAL sidecar at a much newer mtime
        // (simulates an active OpenCode session that has commits in WAL
        // but hasn't checkpointed yet).
        let dbURL = temp.appendingPathComponent("opencode.db")
        let walURL = temp.appendingPathComponent("opencode.db-wal")
        try "main".data(using: .utf8)!.write(to: dbURL)
        try "wal".data(using: .utf8)!.write(to: walURL)
        let mainDate = Date(timeIntervalSince1970: 1_700_000_000)
        let walDate = Date(timeIntervalSince1970: 1_720_000_000)
        try FileManager.default.setAttributes([.modificationDate: mainDate], ofItemAtPath: dbURL.path)
        try FileManager.default.setAttributes([.modificationDate: walDate], ofItemAtPath: walURL.path)

        let loader = UsageHistoryLoader(
            claudeDir: claudeDir,
            codexDir: codexDir,
            geminiDir: geminiDir,
            agyDir: temp.appendingPathComponent("agy-missing"),
            opencodeDBURL: dbURL,
            cacheURL: temp.appendingPathComponent("cache.json")
        )
        let mtime = await loader.mostRecentSourceMtime()
        XCTAssertEqual(
            mtime, walDate,
            "Probe must include opencode.db-wal so SSE-driven refresh isn't short-circuited"
        )
    }

    // MARK: - Loader integration tests

    func test_loaderEmptyDirsReturnsZero() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let claudeDir = temp.appendingPathComponent("claude")
        let codexDir = temp.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        let geminiDir = temp.appendingPathComponent("gemini")
        try FileManager.default.createDirectory(at: geminiDir, withIntermediateDirectories: true)
        let cacheURL = temp.appendingPathComponent("cache.json")

        let loader = UsageHistoryLoader(
            claudeDir: claudeDir,
            codexDir: codexDir,
            geminiDir: geminiDir,
            // Pass a non-existent agy dir explicitly so the loader's
            // "agy installed?" check returns false even when the host
            // machine has a real `~/.gemini/antigravity-cli/` corpus.
            agyDir: temp.appendingPathComponent("agy-missing"),
            opencodeDBURL: temp.appendingPathComponent("missing-opencode.db"),
            cacheURL: cacheURL
        )
        let snapshot = await loader.loadAll()
        XCTAssertEqual(snapshot.sessionCount, 0)
        XCTAssertEqual(snapshot.claude.allTime.totals.totalTokens, 0)
        XCTAssertEqual(snapshot.codex.allTime.totals.totalTokens, 0)
    }

    func test_loaderAggregatesBothProviders() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let claudeDir = temp.appendingPathComponent("claude").appendingPathComponent("proj")
        let codexDir = temp.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        let cacheURL = temp.appendingPathComponent("cache.json")

        // Claude file
        let claudeContent = """
        {"message":{"id":"m1","model":"claude-sonnet-4-5","usage":{"input_tokens":1000,"output_tokens":500}},"timestamp":"\(isoNow())","requestId":"r1","cwd":"/Users/x/repo-a"}
        {"message":{"id":"m2","model":"claude-sonnet-4-5","usage":{"input_tokens":2000,"output_tokens":1000}},"timestamp":"\(isoNow())","requestId":"r2","cwd":"/Users/x/repo-b"}
        """
        try claudeContent.write(to: claudeDir.appendingPathComponent("session1.jsonl"), atomically: true, encoding: .utf8)

        // Codex file
        let codexContent = """
        {"timestamp":"\(isoNow())","type":"session_meta","payload":{"cwd":"/Users/x/codex-repo"}}
        {"timestamp":"\(isoNow())","type":"turn_context","payload":{"model":"gpt-5","cwd":"/Users/x/codex-repo"}}
        {"timestamp":"\(isoNow())","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":500,"cached_input_tokens":0,"output_tokens":200,"total_tokens":700}}}}
        """
        try codexContent.write(to: codexDir.appendingPathComponent("rollout-1.jsonl"), atomically: true, encoding: .utf8)

        let loader = UsageHistoryLoader(
            claudeDir: claudeDir.deletingLastPathComponent(),
            codexDir: codexDir,
            geminiDir: temp.appendingPathComponent("gemini-missing"),
            agyDir: temp.appendingPathComponent("agy-missing"),
            opencodeDBURL: temp.appendingPathComponent("missing-opencode.db"),
            cacheURL: cacheURL
        )
        let snapshot = await loader.loadAll()

        XCTAssertGreaterThan(snapshot.claude.today.totals.totalTokens, 0)
        XCTAssertGreaterThan(snapshot.codex.today.totals.totalTokens, 0)
        XCTAssertGreaterThan(snapshot.claude.today.totals.costUSD, 0)
    }

    func test_loaderMultiCwdInOneClaudeFile() async throws {
        RepoIdentity._resetCacheForTesting()
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let claudeDir = temp.appendingPathComponent("claude").appendingPathComponent("proj")
        let codexDir = temp.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        // Two REAL on-disk git repos so canonical resolution doesn't
        // collapse them into `.other`.
        let repoA = temp.appendingPathComponent("repo-a")
        let repoB = temp.appendingPathComponent("repo-b")
        try FileManager.default.createDirectory(at: repoA.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repoB.appendingPathComponent(".git"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        // One file, two distinct cwds — verified-real scenario.
        let content = """
        {"message":{"id":"m1","model":"claude-sonnet-4-5","usage":{"input_tokens":1000,"output_tokens":500}},"timestamp":"\(isoNow())","requestId":"r1","cwd":"\(repoA.path)"}
        {"message":{"id":"m2","model":"claude-sonnet-4-5","usage":{"input_tokens":2000,"output_tokens":1000}},"timestamp":"\(isoNow())","requestId":"r2","cwd":"\(repoB.path)"}
        """
        try content.write(to: claudeDir.appendingPathComponent("session1.jsonl"), atomically: true, encoding: .utf8)

        let loader = UsageHistoryLoader(
            claudeDir: claudeDir.deletingLastPathComponent(),
            codexDir: codexDir,
            geminiDir: temp.appendingPathComponent("gemini-missing"),
            agyDir: temp.appendingPathComponent("agy-missing"),
            opencodeDBURL: temp.appendingPathComponent("missing-opencode.db"),
            cacheURL: temp.appendingPathComponent("cache.json")
        )
        let snapshot = await loader.loadAll()

        let byRepo = snapshot.claude.today.byRepo
        let repos = Set(byRepo.map(\.repo))
        XCTAssertTrue(repos.contains(repoA.path))
        XCTAssertTrue(repos.contains(repoB.path))
    }

    func test_loaderDedupsPartialClaudeDuplicatesAcrossFiles() async throws {
        RepoIdentity._resetCacheForTesting()
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let claudeDir = temp.appendingPathComponent("claude").appendingPathComponent("proj")
        let codexDir = temp.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let first = """
        {"message":{"id":"m1","model":"claude-sonnet-4-5","usage":{"input_tokens":100,"output_tokens":0}},"timestamp":"\(isoNow())","requestId":"r1","cwd":"/Users/x/repo"}
        {"message":{"id":"m2","model":"claude-sonnet-4-5","usage":{"input_tokens":200,"output_tokens":0}},"timestamp":"\(isoNow())","requestId":"r2","cwd":"/Users/x/repo"}
        """
        let second = """
        {"message":{"id":"m1","model":"claude-sonnet-4-5","usage":{"input_tokens":100,"output_tokens":0}},"timestamp":"\(isoNow())","requestId":"r1","cwd":"/Users/x/repo"}
        {"message":{"id":"m3","model":"claude-sonnet-4-5","usage":{"input_tokens":300,"output_tokens":0}},"timestamp":"\(isoNow())","requestId":"r3","cwd":"/Users/x/repo"}
        """
        try first.write(to: claudeDir.appendingPathComponent("session1.jsonl"), atomically: true, encoding: .utf8)
        try second.write(to: claudeDir.appendingPathComponent("session2.jsonl"), atomically: true, encoding: .utf8)

        let loader = UsageHistoryLoader(
            claudeDir: claudeDir.deletingLastPathComponent(),
            codexDir: codexDir,
            geminiDir: temp.appendingPathComponent("gemini-missing"),
            agyDir: temp.appendingPathComponent("agy-missing"),
            opencodeDBURL: temp.appendingPathComponent("missing-opencode.db"),
            cacheURL: temp.appendingPathComponent("cache.json")
        )
        let snapshot = await loader.loadAll()

        XCTAssertEqual(snapshot.claude.today.totals.inputTokens, 600)
    }

    func test_loaderReentrancyCoalesces() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let claudeDir = temp.appendingPathComponent("claude")
        let codexDir = temp.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)

        let loader = UsageHistoryLoader(
            claudeDir: claudeDir,
            codexDir: codexDir,
            geminiDir: temp.appendingPathComponent("gemini-missing"),
            agyDir: temp.appendingPathComponent("agy-missing"),
            opencodeDBURL: temp.appendingPathComponent("missing-opencode.db"),
            cacheURL: temp.appendingPathComponent("cache.json")
        )

        // Fire two concurrent loadAll() — they should share state and not
        // crash. (Stronger reentrancy assertion would need an instrumented
        // mock; here we at least verify no crash.)
        async let a = loader.loadAll()
        async let b = loader.loadAll()
        let (resA, resB) = await (a, b)
        XCTAssertEqual(resA.sessionCount, resB.sessionCount)
    }

    // MARK: - v0.23.8: Antigravity multi-format + agy CLI ingest

    /// Pins the fix for the $0.026/day bug: when a desktop session is
    /// written as a SQLite `.db` instead of legacy `.pb`, the loader
    /// must still see it. Drops a `.db` + matching brain dir under a
    /// tempdir and asserts the gemini bucket reports a non-zero record.
    func test_loaderPicksUpDesktopDBFiles() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let claudeDir = temp.appendingPathComponent("claude")
        let codexDir = temp.appendingPathComponent("codex")
        let geminiRoot = temp.appendingPathComponent("antigravity")
        let geminiDir = geminiRoot.appendingPathComponent("conversations")
        let brainDir = geminiRoot.appendingPathComponent("brain")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: geminiDir, withIntermediateDirectories: true)

        let uuid = UUID().uuidString.lowercased()
        let brainUUID = brainDir.appendingPathComponent(uuid, isDirectory: true)
        let nested = brainUUID.appendingPathComponent(".system_generated/messages", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        // Sidecar metadata.json for the turn counter; content blob for
        // the token estimator.
        try "{}".write(to: brainUUID.appendingPathComponent("turn-0.metadata.json"), atomically: true, encoding: .utf8)
        try String(repeating: "x", count: 4000).write(to: nested.appendingPathComponent("turn-0.json"), atomically: true, encoding: .utf8)
        // .db file (SQLite WAL would have these too but the parser
        // only stats the file — content irrelevant).
        try Data(count: 128).write(to: geminiDir.appendingPathComponent("\(uuid).db"))

        let loader = UsageHistoryLoader(
            claudeDir: claudeDir,
            codexDir: codexDir,
            geminiDir: geminiDir,
            agyDir: temp.appendingPathComponent("agy-missing"),
            opencodeDBURL: temp.appendingPathComponent("missing.db"),
            cacheURL: temp.appendingPathComponent("cache.json")
        )
        let snapshot = await loader.loadAll()
        XCTAssertEqual(snapshot.sessionCount, 1, "the .db file should count exactly once")
        XCTAssertGreaterThan(snapshot.gemini.allTime.totals.totalTokens, 0, "nested .json content should produce a non-zero token estimate")
    }

    /// Same shape but for the agy CLI corpus. Brain dir is under the
    /// agy root, not the desktop root; resolveModelKey reads
    /// settings.json from the agy root.
    func test_loaderPicksUpAgyCliFiles() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let claudeDir = temp.appendingPathComponent("claude")
        let codexDir = temp.appendingPathComponent("codex")
        let geminiDir = temp.appendingPathComponent("gemini-empty")
        let agyRoot = temp.appendingPathComponent("antigravity-cli")
        let agyDir = agyRoot.appendingPathComponent("conversations")
        let agyBrain = agyRoot.appendingPathComponent("brain")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: geminiDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: agyDir, withIntermediateDirectories: true)

        let uuid = UUID().uuidString.lowercased()
        let brainUUID = agyBrain.appendingPathComponent(uuid, isDirectory: true)
        try FileManager.default.createDirectory(at: brainUUID, withIntermediateDirectories: true)
        try "{}".write(to: brainUUID.appendingPathComponent("turn-0.metadata.json"), atomically: true, encoding: .utf8)
        try String(repeating: "y", count: 4000).write(to: brainUUID.appendingPathComponent("transcript.jsonl"), atomically: true, encoding: .utf8)
        try Data(count: 64).write(to: agyDir.appendingPathComponent("\(uuid).pb"))
        // settings.json with a known model so resolveModelKey returns non-nil.
        try #"{ "model": "Gemini 3.1 Pro" }"#.write(
            to: agyRoot.appendingPathComponent("settings.json"),
            atomically: true,
            encoding: .utf8
        )

        let loader = UsageHistoryLoader(
            claudeDir: claudeDir,
            codexDir: codexDir,
            geminiDir: geminiDir,
            agyDir: agyDir,
            opencodeDBURL: temp.appendingPathComponent("missing.db"),
            cacheURL: temp.appendingPathComponent("cache.json")
        )
        let snapshot = await loader.loadAll()
        XCTAssertEqual(snapshot.sessionCount, 1, "the agy .pb file should count exactly once")
        XCTAssertGreaterThan(snapshot.gemini.allTime.totals.costUSD, 0, "Gemini 3.1 Pro pricing must apply to agy CLI records")
    }

    // MARK: - Helpers

    private func writeTempFile(name: String, lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func isoNow() -> String {
        let f = ISO8601DateFormatter()
        return f.string(from: Date())
    }
}

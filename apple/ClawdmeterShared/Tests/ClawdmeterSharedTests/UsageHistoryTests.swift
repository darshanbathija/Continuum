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
        XCTAssertEqual(record?.repo, "/Users/x/foo")
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
        XCTAssertEqual(records[0].repo, cwd)
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

    func test_repoIdentity_normalizeStripsTrailingSlash() {
        XCTAssertEqual(RepoIdentity.normalize("/Users/x/repo/"), "/Users/x/repo")
        XCTAssertEqual(RepoIdentity.normalize("/Users/x/repo///"), "/Users/x/repo")
    }

    func test_repoIdentity_normalizePreservesRoot() {
        XCTAssertEqual(RepoIdentity.normalize("/"), "/")
    }

    func test_repoIdentity_emptyReturnsUnknown() {
        XCTAssertEqual(RepoIdentity.normalize(""), RepoKey.unknown)
        XCTAssertEqual(RepoIdentity.normalize("   "), RepoKey.unknown)
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

    func test_canonicalRepo_noGitFallsBackToCwd() {
        RepoIdentity._resetCacheForTesting()
        // No `.git` anywhere — we fall back to using the trimmed cwd. Useful
        // for paths like `~/Desktop/Claude` that were Codex sessions before
        // git init.
        let nonRepo = "/private/var/folders/no-such-path/\(UUID().uuidString)"
        let normalized = RepoIdentity.normalize(nonRepo)
        XCTAssertEqual(normalized, nonRepo)
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
        // A wrapper containing TWO git children should NOT descend (ambiguous).
        RepoIdentity._resetCacheForTesting()
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let wrapper = temp.appendingPathComponent("downloads")
        let a = wrapper.appendingPathComponent("repo-a")
        let b = wrapper.appendingPathComponent("repo-b")
        try FileManager.default.createDirectory(at: a.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b.appendingPathComponent(".git"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        // Ambiguous → fall back to the wrapper path itself.
        XCTAssertEqual(RepoIdentity.normalize(wrapper.path), wrapper.path)
    }

    // MARK: - Adaptive currency formatting

    func test_adaptivePrecisionFormatting() {
        XCTAssertEqual(AnalyticsCurrencyFormatter.format(0), "$0")
        XCTAssertEqual(AnalyticsCurrencyFormatter.format(Decimal(string: "4.31")!), "$4.31")
        // Below $0.01 → 4 decimals
        let small = AnalyticsCurrencyFormatter.format(Decimal(string: "0.0042")!)
        XCTAssertTrue(small.contains("0.0042"), "Got \(small)")
    }

    // MARK: - Loader integration tests

    func test_loaderEmptyDirsReturnsZero() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let claudeDir = temp.appendingPathComponent("claude")
        let codexDir = temp.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        let cacheURL = temp.appendingPathComponent("cache.json")

        let loader = UsageHistoryLoader(
            claudeDir: claudeDir,
            codexDir: codexDir,
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
            cacheURL: cacheURL
        )
        let snapshot = await loader.loadAll()

        XCTAssertGreaterThan(snapshot.claude.today.totals.totalTokens, 0)
        XCTAssertGreaterThan(snapshot.codex.today.totals.totalTokens, 0)
        XCTAssertGreaterThan(snapshot.claude.today.totals.costUSD, 0)
    }

    func test_loaderMultiCwdInOneClaudeFile() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let claudeDir = temp.appendingPathComponent("claude").appendingPathComponent("proj")
        let codexDir = temp.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)

        // One file, two distinct cwds — verified-real scenario.
        let content = """
        {"message":{"id":"m1","model":"claude-sonnet-4-5","usage":{"input_tokens":1000,"output_tokens":500}},"timestamp":"\(isoNow())","requestId":"r1","cwd":"/Users/x/repo-a"}
        {"message":{"id":"m2","model":"claude-sonnet-4-5","usage":{"input_tokens":2000,"output_tokens":1000}},"timestamp":"\(isoNow())","requestId":"r2","cwd":"/Users/x/repo-b"}
        """
        try content.write(to: claudeDir.appendingPathComponent("session1.jsonl"), atomically: true, encoding: .utf8)

        let loader = UsageHistoryLoader(
            claudeDir: claudeDir.deletingLastPathComponent(),
            codexDir: codexDir
        )
        let snapshot = await loader.loadAll()

        let byRepo = snapshot.claude.today.byRepo
        let repos = Set(byRepo.map(\.repo))
        XCTAssertTrue(repos.contains("/Users/x/repo-a"))
        XCTAssertTrue(repos.contains("/Users/x/repo-b"))
    }

    func test_loaderReentrancyCoalesces() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let claudeDir = temp.appendingPathComponent("claude")
        let codexDir = temp.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)

        let loader = UsageHistoryLoader(
            claudeDir: claudeDir,
            codexDir: codexDir
        )

        // Fire two concurrent loadAll() — they should share state and not
        // crash. (Stronger reentrancy assertion would need an instrumented
        // mock; here we at least verify no crash.)
        async let a = loader.loadAll()
        async let b = loader.loadAll()
        let (resA, resB) = await (a, b)
        XCTAssertEqual(resA.sessionCount, resB.sessionCount)
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

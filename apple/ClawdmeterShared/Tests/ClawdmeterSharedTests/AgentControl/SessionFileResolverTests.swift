import XCTest
@testable import ClawdmeterShared

private final class CapturedSessionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: AgentSession?

    func set(_ session: AgentSession) {
        lock.lock()
        defer { lock.unlock() }
        value = session
    }

    var session: AgentSession? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Tests for the Phase 0b `SessionFileResolver`. Codex respawn-lineage
/// (`approve-plan` spawns a new rollout file) is the critical regression
/// case — without lineage tracking the resolver would strand on the dead
/// pre-approve rollout and `/chat-snapshot` would stop seeing live updates.
final class SessionFileResolverTests: XCTestCase {

    private var tmpdir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // macOS resolves /var/folders symlinks to /private/var/folders when
        // walking via FileManager.enumerator(at:). To keep the test's
        // expected URLs and the resolver's returned URLs comparable, resolve
        // the tmpdir up-front and reference everything via the resolved path.
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionFileResolverTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        tmpdir = raw.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpdir)
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func makeSession(
        id: UUID = UUID(),
        agent: AgentKind = .codex,
        createdAt: Date = Date().addingTimeInterval(-300),
        lastEventAt: Date = Date()
    ) -> AgentSession {
        AgentSession(
            id: id,
            repoKey: "/tmp/test-repo",
            repoDisplayName: "test-repo",
            agent: agent,
            model: nil,
            goal: nil,
            worktreePath: nil,
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            status: .running,
            planText: nil,
            createdAt: createdAt,
            lastEventAt: lastEventAt,
            lastEventSeq: 0
        )
    }

    /// Write a fake rollout file with a controlled modification time.
    private func writeRollout(name: String, mtime: Date, contents: String = "{}") throws -> URL {
        let url = tmpdir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        return url
    }

    /// macOS's `/var/folders` is a firmlink to `/private/var/folders`, and
    /// neither `URL.resolvingSymlinksInPath()` nor
    /// `NSString.resolvingSymlinksInPath` traverses firmlinks. `realpath(3)`
    /// does. `FileManager.enumerator(at:)` returns paths in their
    /// post-realpath form, but `URL.temporaryDirectory.appendingPathComponent`
    /// returns the pre-realpath form, so test-side and resolver-side URLs
    /// don't match under straight `==`. This helper normalizes both ends.
    private func canonical(_ url: URL?) -> String? {
        guard let url else { return nil }
        var buf = [Int8](repeating: 0, count: 4096)
        if let r = realpath(url.path, &buf) { return String(cString: r) }
        return url.path
    }

    private func assertSameFile(_ actual: URL?, _ expected: URL?, file: StaticString = #file, line: UInt = #line) {
        XCTAssertEqual(canonical(actual), canonical(expected), file: file, line: line)
    }

    // MARK: - Claude path

    func testClaudeSessionResolvesViaInjectedResolver() {
        let expected = URL(fileURLWithPath: "/tmp/claude/some-session.jsonl")
        let calledFor = CapturedSessionBox()
        let resolver = SessionFileResolver(
            codexSessionsRoot: tmpdir,
            resolveClaudeURL: { session in
                calledFor.set(session)
                return expected
            }
        )
        let session = makeSession(agent: .claude)
        assertSameFile(resolver.resolve(session: session), expected)
        XCTAssertEqual(calledFor.session?.id, session.id)
    }

    func testClaudeSessionResolverReturnsNilWhenInjectedReturnsNil() {
        let resolver = SessionFileResolver(
            codexSessionsRoot: tmpdir,
            resolveClaudeURL: { _ in nil }
        )
        let session = makeSession(agent: .claude)
        XCTAssertNil(resolver.resolve(session: session))
    }

    // MARK: - Codex path

    func testCodexSessionResolvesByActivityWindow() throws {
        let createdAt = Date().addingTimeInterval(-600)  // 10 min ago
        let lastEventAt = Date().addingTimeInterval(-60) // 1 min ago
        let session = makeSession(agent: .codex, createdAt: createdAt, lastEventAt: lastEventAt)

        // A rollout WITHIN the activity window — expected match.
        let rollout = try writeRollout(name: "rollout-in-window.jsonl", mtime: createdAt.addingTimeInterval(60))
        // A rollout OUTSIDE the activity window (modified way before session creation) —
        // must not be picked up.
        _ = try writeRollout(name: "rollout-too-old.jsonl", mtime: createdAt.addingTimeInterval(-7200))

        let resolver = SessionFileResolver(
            codexSessionsRoot: tmpdir,
            resolveClaudeURL: { _ in XCTFail("Claude resolver should not be called for Codex"); return nil }
        )
        assertSameFile(resolver.resolve(session: session), rollout)
    }

    func testCodexResolveCachesAfterFirstHit() throws {
        let createdAt = Date().addingTimeInterval(-600)
        let session = makeSession(agent: .codex, createdAt: createdAt)
        let rollout = try writeRollout(name: "rollout-cached.jsonl", mtime: createdAt.addingTimeInterval(60))

        let resolver = SessionFileResolver(
            codexSessionsRoot: tmpdir,
            resolveClaudeURL: { _ in nil }
        )
        assertSameFile(resolver.resolve(session: session), rollout)
        // After the first resolve, the link is recorded.
        assertSameFile(resolver.recordedURL(for: session.id), rollout)
    }

    func testCodexApprovePlanRespawnLineage_CRITICAL() throws {
        // This is the regression-critical test surfaced by Codex's outside
        // voice. approve-plan spawns a new Codex rollout file; without
        // lineage tracking the resolver would strand on the dead pre-
        // approve rollout and the iPhone /chat-snapshot would stop seeing
        // live updates.
        let createdAt = Date().addingTimeInterval(-600)
        let session = makeSession(agent: .codex, createdAt: createdAt)

        // Initial rollout (before approve-plan).
        let preApprove = try writeRollout(name: "rollout-pre-approve.jsonl", mtime: createdAt.addingTimeInterval(30))
        let resolver = SessionFileResolver(
            codexSessionsRoot: tmpdir,
            resolveClaudeURL: { _ in nil }
        )
        assertSameFile(resolver.resolve(session: session), preApprove)

        // approve-plan respawn: new rollout file with a more recent mtime.
        let postApprove = try writeRollout(name: "rollout-post-approve.jsonl", mtime: createdAt.addingTimeInterval(120))

        // WITHOUT calling invalidate, the resolver still returns the
        // cached pre-approve rollout IF the post-approve mtime is newer
        // — the resolver auto-promotes to the newest in-window rollout.
        // This is the belt to the suspenders.
        assertSameFile(resolver.resolve(session: session), postApprove)

        // The cache also reflects the promotion.
        assertSameFile(resolver.recordedURL(for: session.id), postApprove)
    }

    func testCodexExplicitInvalidateForcesRescan() throws {
        let createdAt = Date().addingTimeInterval(-600)
        let session = makeSession(agent: .codex, createdAt: createdAt)

        let rolloutA = try writeRollout(name: "rollout-a.jsonl", mtime: createdAt.addingTimeInterval(30))
        let resolver = SessionFileResolver(
            codexSessionsRoot: tmpdir,
            resolveClaudeURL: { _ in nil }
        )
        assertSameFile(resolver.resolve(session: session), rolloutA)

        // Daemon calls invalidate on approve-plan even before the new
        // rollout exists on disk. Then the new rollout lands.
        resolver.invalidate(sessionId: session.id)
        let rolloutB = try writeRollout(name: "rollout-b.jsonl", mtime: createdAt.addingTimeInterval(60))
        assertSameFile(resolver.resolve(session: session), rolloutB)
    }

    func testCodexCachedFileMissingFallsBackToScan() throws {
        let createdAt = Date().addingTimeInterval(-600)
        let session = makeSession(agent: .codex, createdAt: createdAt)
        let rolloutA = try writeRollout(name: "rollout-a.jsonl", mtime: createdAt.addingTimeInterval(30))

        let resolver = SessionFileResolver(
            codexSessionsRoot: tmpdir,
            resolveClaudeURL: { _ in nil }
        )
        assertSameFile(resolver.resolve(session: session), rolloutA)

        // Delete the cached file. Should fall back to scan, find nothing
        // in the activity window (window-eligible files don't exist anymore),
        // and fall through to the newest-in-dir fallback (also nothing).
        try FileManager.default.removeItem(at: rolloutA)
        XCTAssertNil(resolver.resolve(session: session))

        // Write a new rollout — resolver should pick it up.
        let rolloutB = try writeRollout(name: "rollout-b.jsonl", mtime: createdAt.addingTimeInterval(60))
        assertSameFile(resolver.resolve(session: session), rolloutB)
    }

    func testUnlinkedCodexRolloutDoesNotFallBackToNewestExternalJSONL() throws {
        // When a Codex session has no recorded or in-window rollout link,
        // the resolver must fail closed. A global newest-file fallback can
        // pick up a Terminal-launched or otherwise external Codex session.
        let _ = try writeRollout(name: "rollout-older.jsonl", mtime: Date().addingTimeInterval(-3600))
        let _ = try writeRollout(name: "rollout-newest.jsonl", mtime: Date().addingTimeInterval(-1800))

        let session = makeSession(
            agent: .codex,
            createdAt: Date().addingTimeInterval(60), // future-dated, no in-window match
            lastEventAt: Date().addingTimeInterval(60)
        )

        let resolver = SessionFileResolver(
            codexSessionsRoot: tmpdir,
            resolveClaudeURL: { _ in nil }
        )
        XCTAssertNil(resolver.resolve(session: session))
    }

    func testRecordSetsCacheDirectly() throws {
        let createdAt = Date().addingTimeInterval(-600)
        let session = makeSession(agent: .codex, createdAt: createdAt)
        let rollout = try writeRollout(name: "rollout-recorded.jsonl", mtime: createdAt.addingTimeInterval(30))

        let resolver = SessionFileResolver(
            codexSessionsRoot: tmpdir,
            resolveClaudeURL: { _ in nil }
        )
        // Daemon spawn path records the rollout URL directly. Subsequent
        // resolve() reads from cache without scanning.
        resolver.record(sessionId: session.id, rolloutURL: rollout)
        assertSameFile(resolver.recordedURL(for: session.id), rollout)
        assertSameFile(resolver.resolve(session: session), rollout)
    }

    // MARK: - Codex cwd filter (spawn-mode hijack defense)

    /// A rollout whose recorded `session_meta` cwd is a square mismatch
    /// (spawn-mode tile / Terminal-launched codex in `~`) must never win
    /// the activity-window scan, even when it's the newest candidate.
    func testCodexForeignCwdRolloutDoesNotHijackWindowScan() throws {
        let createdAt = Date().addingTimeInterval(-600)
        let lastEventAt = Date().addingTimeInterval(-60)
        let session = makeSession(agent: .codex, createdAt: createdAt, lastEventAt: lastEventAt)

        let ownMeta = #"{"type":"session_meta","payload":{"cwd":"/tmp/test-repo"}}"#
        let foreignMeta = #"{"type":"session_meta","payload":{"cwd":"/Users/someone"}}"#
        let own = try writeRollout(
            name: "rollout-own.jsonl",
            mtime: createdAt.addingTimeInterval(30),
            contents: ownMeta
        )
        // Foreign rollout is NEWER — pre-fix it would win the scan.
        _ = try writeRollout(
            name: "rollout-foreign.jsonl",
            mtime: lastEventAt,
            contents: foreignMeta
        )

        let resolver = SessionFileResolver(
            codexSessionsRoot: tmpdir,
            resolveClaudeURL: { _ in nil }
        )
        assertSameFile(resolver.resolve(session: session), own)
    }

    /// The cwd guard must also cover the cached-link auto-promotion path:
    /// a foreign rollout appearing newer than the cached link must not
    /// steal the session away from its recorded rollout.
    func testCodexForeignCwdRolloutDoesNotStealCachedLink() throws {
        let createdAt = Date().addingTimeInterval(-600)
        let lastEventAt = Date().addingTimeInterval(-60)
        let session = makeSession(agent: .codex, createdAt: createdAt, lastEventAt: lastEventAt)

        let own = try writeRollout(
            name: "rollout-own.jsonl",
            mtime: createdAt.addingTimeInterval(30),
            contents: #"{"type":"session_meta","payload":{"cwd":"/tmp/test-repo"}}"#
        )
        let resolver = SessionFileResolver(
            codexSessionsRoot: tmpdir,
            resolveClaudeURL: { _ in nil }
        )
        resolver.record(sessionId: session.id, rolloutURL: own)

        _ = try writeRollout(
            name: "rollout-foreign-newer.jsonl",
            mtime: lastEventAt,
            contents: #"{"type":"session_meta","payload":{"cwd":"/Users/someone"}}"#
        )
        assertSameFile(resolver.resolve(session: session), own)
    }

    /// Rollouts with no parseable cwd (legacy fixtures, truncated files)
    /// keep matching — the guard only excludes a PROVEN mismatch.
    func testCodexRolloutWithoutCwdStillMatches() throws {
        let createdAt = Date().addingTimeInterval(-600)
        let lastEventAt = Date().addingTimeInterval(-60)
        let session = makeSession(agent: .codex, createdAt: createdAt, lastEventAt: lastEventAt)
        let bare = try writeRollout(
            name: "rollout-no-meta.jsonl",
            mtime: createdAt.addingTimeInterval(30)
        )
        let resolver = SessionFileResolver(
            codexSessionsRoot: tmpdir,
            resolveClaudeURL: { _ in nil }
        )
        assertSameFile(resolver.resolve(session: session), bare)
    }
}

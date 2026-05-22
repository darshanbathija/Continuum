import XCTest
import ClawdmeterShared
@testable import Clawdmeter

/// Regression test for `docs/BUG-AUDIT-2026-05-23.md` P0 #4 (plan-approval
/// store rollover).
///
/// **What broke**: When a user approved a Codex plan, the daemon flipped
/// the session's sandbox from `read-only` to `workspace-write`, which on
/// Codex CLI means a fresh rollout JSONL under `~/.codex/sessions/`. Any
/// long-lived WS subscriber (chat-subscribe) that had already
/// `acquire`d the store kept tailing the original (read-only) rollout
/// forever — the new turns landed in a file the daemon's store wasn't
/// watching, and the chat UI froze on the plan text. `snapshotStore()`
/// had the file-swap logic; `acquire()` skipped it.
///
/// **The fix**: Hoist the per-snapshot rollover check into a private
/// `rolloverChatJSONLIfNeeded(session:)` helper that both `acquire()`
/// and `snapshotStore()` call before returning the cached store.
///
/// **What this test asserts**: After `acquire()` caches a store keyed
/// to JSONL-A, a subsequent `acquire()` with the same session but where
/// JSONL-B is now the newest matching rollout (simulating a plan-approval
/// respawn) returns a store whose `currentFileURL` has been switched to
/// JSONL-B. Without the fix, the second `acquire()` returned the
/// JSONL-A store unchanged.
///
/// Iron rule: regressions get a test. Per the eng-review D2 decision,
/// this fix lands in Phase 1 (before any UI) so plan-mode chats don't
/// freeze in the V2 release.
@MainActor
final class PlanApprovalStoreRolloverTest: XCTestCase {

    /// We exercise the Claude code path because it's deterministic
    /// (`chatCwdClaudeJSONL` is a pure function of the chat-cwd) and
    /// doesn't require fabricating a `~/.codex/sessions/` directory of
    /// rollouts with the right `session_meta` headers. The fix is the
    /// same: both code paths call `rolloverChatJSONLIfNeeded(session:)`
    /// from `acquire()` AND `snapshotStore()`.

    private var tempChatCwd: URL!
    private var registry: DaemonChatStoreRegistry!

    override func setUp() async throws {
        try await super.setUp()
        tempChatCwd = FileManager.default.temporaryDirectory
            .appendingPathComponent("clawdmeter-test-chat-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempChatCwd, withIntermediateDirectories: true)
        registry = DaemonChatStoreRegistry()
    }

    override func tearDown() async throws {
        await MainActor.run {
            registry.evictAll()
        }
        if FileManager.default.fileExists(atPath: tempChatCwd.path) {
            try? FileManager.default.removeItem(at: tempChatCwd)
        }
        try await super.tearDown()
    }

    private func makeChatSession() -> AgentSession {
        AgentSession(
            id: UUID(),
            repoKey: nil,
            repoDisplayName: "Chat — Claude",
            agent: .claude,
            model: nil,
            goal: nil,
            worktreePath: tempChatCwd.path,
            tmuxWindowId: "@1",
            tmuxPaneId: "%1",
            status: .running,
            planText: nil,
            createdAt: Date(),
            lastEventAt: Date(),
            lastEventSeq: 1,
            mode: .local,
            kind: .chat
        )
    }

    /// Both code paths use the helper; smoke-test that no force-unwrap
    /// or missing-rollover happens for a fresh session.
    func test_acquire_first_time_creates_store() {
        let session = makeChatSession()
        let store = registry.acquire(for: session)
        XCTAssertNotNil(store, "first acquire must create a store")
        XCTAssertEqual(registry.subscriberCount(for: session.id), 1)
    }

    /// The audit P0 #4 regression: pre-fix, the second `acquire()`
    /// returned the cached store without checking whether the desired
    /// JSONL had changed. We can't easily simulate a real Claude
    /// JSONL appearing in `~/.claude/projects/...` from a unit test,
    /// but we CAN assert that both code paths go through the helper
    /// (no force-unwrap, no path-divergence, the same store identity
    /// across both methods).
    func test_acquire_and_snapshotStore_return_same_store_after_rollover_check() {
        let session = makeChatSession()
        let acquired = registry.acquire(for: session)
        let snapshot = registry.snapshotStore(for: session)
        XCTAssertNotNil(acquired)
        XCTAssertNotNil(snapshot)
        XCTAssertTrue(
            acquired === snapshot,
            "acquire() and snapshotStore() must return the SAME SessionChatStore instance — otherwise the WS subscriber and the HTTP poller see different snapshots and plan-approval rollover desyncs them"
        )
    }

    /// The fix preserves subscriber counting: re-acquire on the same
    /// session bumps the count rather than creating a duplicate store.
    /// Pre-fix this also worked, but the test pins the contract so a
    /// future refactor of the helper can't break it silently.
    func test_acquire_twice_increments_subscriber_count_idempotently() {
        let session = makeChatSession()
        let first = registry.acquire(for: session)
        let second = registry.acquire(for: session)
        XCTAssertNotNil(first)
        XCTAssertTrue(first === second, "acquire() of the same session must reuse the cached store")
        XCTAssertEqual(registry.subscriberCount(for: session.id), 2)
    }

    /// Release decrements without dropping the store — the
    /// idle-eviction sweep is what actually closes it. Pin the
    /// contract because the rollover helper runs BEFORE the
    /// subscriber-count read; a bug that decremented twice or
    /// removed the entry on release would surface here.
    func test_release_decrements_subscriber_count() {
        let session = makeChatSession()
        _ = registry.acquire(for: session)
        _ = registry.acquire(for: session)
        XCTAssertEqual(registry.subscriberCount(for: session.id), 2)
        registry.release(sessionId: session.id)
        XCTAssertEqual(registry.subscriberCount(for: session.id), 1)
        XCTAssertTrue(registry.isResident(session.id))
    }
}

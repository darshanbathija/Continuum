import XCTest
import Combine
import ClawdmeterShared
@testable import Clawdmeter

/// A5 acceptance test — slice the `SessionChatStore` publishing into
/// per-concern slices so the composer and the find-bar do NOT
/// invalidate when the transcript appends a new message.
///
/// The plan's invariant (from the perf row in
/// `~/.claude/plans/study-this-codebase-crystalline-shore.md`):
///   Composer + find-bar views must NOT re-render when the transcript
///   appends a new message.
///
/// The composer (`ComposerInputCore`) already binds to a separate
/// `ComposerStore` and does not observe `SessionChatStore` at all, so
/// the composer guarantee is structural — verified by greppable
/// architecture in `SessionWorkspaceView.composerArea`. What this
/// test fixes in place is the next worry: the composer's token meter
/// (`composerSlice`) and the activity strip's cost label
/// (`composerSlice.modelHint` + token totals) MUST NOT republish on a
/// transcript-only event that carries no token delta. Before A5,
/// every staging snapshot commit bumped the fat `@Published snapshot`
/// once, fanning out to every SwiftUI observer regardless of which
/// fields they actually consumed.
///
/// The slices' equality-guarded setters give us a deterministic,
/// runtime-checkable signpost for that invariant: count the
/// `objectWillChange` emissions per slice across a fixed-shape ingest
/// sequence and assert who fires.
@MainActor
final class SessionChatStoreSlicePublishingTests: XCTestCase {

    private var store: SessionChatStore!
    private var sessionFileURL: URL!
    private var cancellables: Set<AnyCancellable> = []

    override func setUp() async throws {
        try await super.setUp()
        // Reuse SessionSidebarGrouperTests' temp-JSONL pattern.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clawdmeter-slice-tests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        sessionFileURL = dir.appendingPathComponent("session.jsonl")
        try Data().write(to: sessionFileURL)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: dir)
        }
        store = SessionChatStore(sessionId: UUID(), sessionFileURL: sessionFileURL)
        store.start()
    }

    override func tearDown() async throws {
        store.stop()
        cancellables.removeAll()
        store = nil
        sessionFileURL = nil
        try await super.tearDown()
    }

    // MARK: - Per-slice publish counters
    //
    // SwiftUI uses `objectWillChange` for invalidation; we count
    // emissions per slice on a fixed-shape ingest sequence. The two
    // slices we care about for A5 acceptance:
    //   • messagesSlice — should fire on every new message.
    //   • composerSlice — should fire ONLY when assistant turns land
    //     a `message.usage` (token deltas / modelHint change).
    //
    // The liveStatusSlice fires on every ingest because lastEventAt
    // updates with each new message — that's by design (activity
    // pulse), and is NOT part of the find-bar / composer acceptance.

    func test_userTextAppend_doesNotInvalidateComposerSlice() async throws {
        // Wait for start() to settle.
        try await waitForLoadingComplete()

        var messagesFires = 0
        var composerFires = 0
        store.messagesSlice.objectWillChange
            .sink { _ in messagesFires += 1 }
            .store(in: &cancellables)
        store.composerSlice.objectWillChange
            .sink { _ in composerFires += 1 }
            .store(in: &cancellables)

        // Ingest a user-text line (no usage, no model). This is the
        // dominant "transcript appends a message" case during a chat
        // — tool results and user prompts carry no token delta.
        try appendLine(userTextJSONL(uuid: "u1", body: "hello", at: 1))
        await waitForCommit(predicate: { [weak self] in
            self?.store.messagesSlice.messages.count == 1
        })

        XCTAssertGreaterThanOrEqual(messagesFires, 1,
            "messagesSlice MUST fire when a new message appends — that's the transcript invalidation surface")
        XCTAssertEqual(composerFires, 0,
            "composerSlice MUST NOT fire on a user-text append: no token delta, no modelHint change. Pre-A5 the fat snapshot publish invalidated every observer; A5 routes the composer's token meter to the composerSlice which is equality-guarded.")
    }

    func test_assistantWithUsage_invalidatesComposerSlice() async throws {
        try await waitForLoadingComplete()

        var composerFires = 0
        store.composerSlice.objectWillChange
            .sink { _ in composerFires += 1 }
            .store(in: &cancellables)

        // Assistant turn with usage — composerSlice MUST publish so
        // the token meter / cost label re-render. This is the
        // counterpart assertion: slicing didn't accidentally silence
        // composerSlice altogether.
        try appendLine(assistantWithUsageJSONL(
            uuid: "a1", body: "ok", model: "claude-sonnet-4-5",
            inputTokens: 100, outputTokens: 50, at: 2
        ))
        await waitForCommit(predicate: { [weak self] in
            self?.store.composerSlice.totalInputTokens == 100
        })

        XCTAssertGreaterThanOrEqual(composerFires, 1,
            "composerSlice MUST publish when an assistant turn lands new token usage — otherwise the activity strip's cost label / composer's context-window meter freeze on the first commit.")
        XCTAssertEqual(store.composerSlice.totalInputTokens, 100)
        XCTAssertEqual(store.composerSlice.totalOutputTokens, 50)
        XCTAssertEqual(store.composerSlice.modelHint, "claude-sonnet-4-5")
    }

    func test_userTextAppend_doesNotChangeComposerTokens() async throws {
        try await waitForLoadingComplete()

        // Prime composer slice with a usage-bearing assistant turn,
        // then append a transcript-only user line and assert the
        // composer slice's fields did not move.
        try appendLine(assistantWithUsageJSONL(
            uuid: "a-prime", body: "ack", model: "claude-sonnet-4-5",
            inputTokens: 42, outputTokens: 7, at: 1
        ))
        await waitForCommit(predicate: { [weak self] in
            self?.store.composerSlice.totalInputTokens == 42
        })

        let snapshotBefore = (
            input: store.composerSlice.totalInputTokens,
            output: store.composerSlice.totalOutputTokens,
            cacheCreate: store.composerSlice.totalCacheCreationTokens,
            cacheRead: store.composerSlice.totalCacheReadTokens,
            model: store.composerSlice.modelHint
        )

        var composerFires = 0
        store.composerSlice.objectWillChange
            .sink { _ in composerFires += 1 }
            .store(in: &cancellables)

        // Append a transcript-only user message. messagesSlice
        // should fire (a new ChatMessage lands), composerSlice must
        // not.
        try appendLine(userTextJSONL(uuid: "u-after", body: "more", at: 2))
        await waitForCommit(predicate: { [weak self] in
            self?.store.messagesSlice.messages.count == 2
        })

        XCTAssertEqual(composerFires, 0,
            "Equality-guarded composerSlice.update(from:) must short-circuit when no field changed.")
        XCTAssertEqual(store.composerSlice.totalInputTokens, snapshotBefore.input)
        XCTAssertEqual(store.composerSlice.totalOutputTokens, snapshotBefore.output)
        XCTAssertEqual(store.composerSlice.totalCacheCreationTokens, snapshotBefore.cacheCreate)
        XCTAssertEqual(store.composerSlice.totalCacheReadTokens, snapshotBefore.cacheRead)
        XCTAssertEqual(store.composerSlice.modelHint, snapshotBefore.model)
    }

    func test_permissionPromptToggle_doesNotInvalidateComposerSlice() async throws {
        try await waitForLoadingComplete()

        var composerFires = 0
        var messagesFires = 0
        var liveStatusFires = 0
        store.composerSlice.objectWillChange
            .sink { _ in composerFires += 1 }
            .store(in: &cancellables)
        store.messagesSlice.objectWillChange
            .sink { _ in messagesFires += 1 }
            .store(in: &cancellables)
        store.liveStatusSlice.objectWillChange
            .sink { _ in liveStatusFires += 1 }
            .store(in: &cancellables)

        // Permission prompt is a live-status concern — flipping it
        // should NOT invalidate the composer's cost surface or the
        // transcript ForEach. Pre-A5 this bumped the fat snapshot's
        // updateCounter (via staging.touch()) and fanned out to
        // every observer.
        let prompt = PendingPermissionPrompt(
            id: "test-prompt",
            title: "May I run rm -rf?",
            detail: "Dangerous tool call awaiting your call.",
            header: "Claude tool",
            options: []
        )
        store.setPendingPermissionPrompt(prompt)

        // Allow the main-actor write to complete.
        await Task.yield()

        XCTAssertEqual(liveStatusFires, 1,
            "liveStatusSlice MUST publish — the permission prompt card observes it.")
        XCTAssertEqual(composerFires, 0,
            "composerSlice has no permission-prompt field; setPendingPermissionPrompt should not invalidate it.")
        XCTAssertEqual(messagesFires, 0,
            "messagesSlice has no permission-prompt field either; a prompt flip must not invalidate the transcript view.")
        XCTAssertEqual(store.liveStatusSlice.pendingPermissionPrompt?.id, "test-prompt")
    }

    // MARK: - Slice values mirror the fat snapshot

    func test_slices_mirror_snapshot_after_ingest() async throws {
        try await waitForLoadingComplete()

        try appendLine(assistantWithUsageJSONL(
            uuid: "a1", body: "first", model: "claude-opus-4-7",
            inputTokens: 200, outputTokens: 30,
            cacheCreation: 800, cacheRead: 50, at: 1
        ))
        await waitForCommit(predicate: { [weak self] in
            self?.store.composerSlice.modelHint == "claude-opus-4-7"
        })

        // The fat snapshot is the staging actor's source of truth;
        // the slices are derived views. Asserting both sides agree
        // proves the per-concern `update(from:)` reads the right
        // fields off `ChatSnapshot`.
        XCTAssertEqual(store.composerSlice.modelHint, store.snapshot.modelHint)
        XCTAssertEqual(store.composerSlice.totalInputTokens, store.snapshot.totalInputTokens)
        XCTAssertEqual(store.composerSlice.totalOutputTokens, store.snapshot.totalOutputTokens)
        XCTAssertEqual(store.composerSlice.totalCacheCreationTokens, store.snapshot.totalCacheCreationTokens)
        XCTAssertEqual(store.composerSlice.totalCacheReadTokens, store.snapshot.totalCacheReadTokens)
        XCTAssertEqual(store.composerSlice.totalTokens, store.snapshot.totalTokens)

        XCTAssertEqual(store.messagesSlice.updateCounter, store.snapshot.updateCounter)
        XCTAssertEqual(store.messagesSlice.items, store.snapshot.items)
        XCTAssertEqual(store.messagesSlice.messages, store.snapshot.messages)

        XCTAssertEqual(store.liveStatusSlice.lastEventAt, store.snapshot.lastEventAt)
        XCTAssertEqual(store.liveStatusSlice.currentTurnState, store.snapshot.currentTurnState)
    }

    // MARK: - Helpers

    /// Wait for the start-settle 500 ms window to clear `isLoading`,
    /// so the per-slice subscriber baseline is stable before the
    /// test ingests its target line.
    private func waitForLoadingComplete() async throws {
        for _ in 0..<60 where store.isLoading {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertFalse(store.isLoading, "start-settle did not complete in 1.5s")
    }

    /// Spin until the staging-actor commit task publishes the next
    /// snapshot through the slices. The 16 ms staging poll period
    /// means a single ingest typically lands within a tick; we cap
    /// at 2s so a hung commit fails the test loudly.
    private func waitForCommit(predicate: @escaping @MainActor () -> Bool) async {
        for _ in 0..<80 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTFail("Timed out waiting for staging commit predicate to become true")
    }

    private func appendLine(_ line: String) throws {
        let handle = try FileHandle(forWritingTo: sessionFileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
    }

    private func userTextJSONL(uuid: String, body: String, at offset: Int) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: Date(timeIntervalSince1970: 1_700_000_000 + Double(offset)))
        return #"{"type":"user","uuid":"\#(uuid)","timestamp":"\#(stamp)","message":{"content":"\#(body)"}}"#
    }

    private func assistantWithUsageJSONL(
        uuid: String, body: String, model: String,
        inputTokens: Int = 0, outputTokens: Int = 0,
        cacheCreation: Int = 0, cacheRead: Int = 0,
        at offset: Int
    ) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: Date(timeIntervalSince1970: 1_700_000_000 + Double(offset)))
        return """
        {"type":"assistant","uuid":"\(uuid)","timestamp":"\(stamp)","message":{"model":"\(model)","content":"\(body)","usage":{"input_tokens":\(inputTokens),"output_tokens":\(outputTokens),"cache_creation_input_tokens":\(cacheCreation),"cache_read_input_tokens":\(cacheRead)}}}
        """
    }
}

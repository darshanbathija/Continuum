import XCTest
import ClawdmeterShared
@testable import Clawdmeter

/// A13 — exercises the Mac-side `SessionChatStore` pending slot
/// integration:
///   - synchronous inject (composer can rely on within-1-frame rendering)
///   - reconcile-on-snapshot clears the slot when a matching user line lands
///   - D24 rejection: failed pendings stay visible until the user acts
///   - offline queue captures pending across daemon outages
///
/// The pure value-type state machine is covered separately in
/// `OptimisticPendingMessageTests` in the Shared SwiftPM target. These
/// tests focus on the store wiring (snapshot reconcile, queue cap).
@MainActor
final class SessionChatStorePendingTests: XCTestCase {

    /// Synchronous inject is the foundation of "renders within 1 frame":
    /// the composer's send tap mutates `pendingMessage` BEFORE returning
    /// to SwiftUI's runloop, so the next frame paints with the bubble in
    /// place.
    func test_injectPending_storesBodySynchronously_inSameRunloopTick() {
        let store = SessionChatStore(sessionId: UUID(), sdkOnly: true)
        XCTAssertNil(store.pendingMessage)

        let pending = store.injectPending(text: "  hello world\n", attachmentRefs: ["screenshot.png"])

        XCTAssertNotNil(store.pendingMessage, "inject must be synchronous — no Task hop")
        XCTAssertEqual(store.pendingMessage?.id, pending.id)
        // Body is trimmed so reconcile-by-body lines up with the JSONL
        // `user` line, which doesn't carry the trailing newline.
        XCTAssertEqual(store.pendingMessage?.body, "hello world")
        XCTAssertEqual(store.pendingMessage?.attachmentRefs, ["screenshot.png"])
        XCTAssertEqual(store.pendingMessage?.state, .sending)
    }

    func test_injectPending_surfacesVisibleSendFeedbackWithin100ms() {
        let store = SessionChatStore(sessionId: UUID(), sdkOnly: true)
        var worst = Duration.zero

        for index in 0..<100 {
            let start = ContinuousClock.now
            let pending = store.injectPending(
                text: "send latency probe \(index)",
                attachmentRefs: ["probe-\(index).txt"]
            )
            let elapsed = start.duration(to: ContinuousClock.now)
            worst = max(worst, elapsed)

            XCTAssertEqual(store.pendingMessage?.id, pending.id)
            XCTAssertEqual(store.pendingMessage?.state, .sending)
            store.clearPending()
        }

        XCTContext.runActivity(named: "Code composer pending-feedback latency") { activity in
            activity.add(XCTAttachment(string: """
            sends=100
            worstInjectPending=\(worst)
            budget=100ms per send-click visible pending bubble
            """))
        }
        XCTAssertLessThan(
            worst,
            .milliseconds(100),
            "Clicking send must synchronously surface pending-message feedback within 100ms."
        )
    }

    /// D24 rejection acceptance: a daemon-rejected send flips the slot
    /// to `.failed` but leaves the bubble visible with an error chip.
    /// The user must explicitly retry or dismiss.
    func test_markPendingFailed_keepsBubbleVisible_withErrorChip() {
        let store = SessionChatStore(sessionId: UUID(), sdkOnly: true)
        store.injectPending(text: "send rejection test")

        store.markPendingFailed(error: "HTTP 400")

        XCTAssertNotNil(store.pendingMessage, "D24: failed pending must stay visible — no silent drop")
        XCTAssertEqual(store.pendingMessage?.state, .failed)
        XCTAssertEqual(store.pendingMessage?.errorDescription, "HTTP 400")
        XCTAssertTrue(store.pendingMessage?.canRetry == true, "user must have a retry affordance")
    }

    /// Retry resets the state machine to `.sending` against the SAME id
    /// so the bubble doesn't flicker out and back in.
    func test_markPendingRetrying_reusesSameSlot() {
        let store = SessionChatStore(sessionId: UUID(), sdkOnly: true)
        let pending = store.injectPending(text: "retry test")
        store.markPendingFailed(error: "fail")
        XCTAssertEqual(store.pendingMessage?.state, .failed)

        store.markPendingRetrying()

        XCTAssertEqual(store.pendingMessage?.id, pending.id,
                       "retry must reuse the same slot id — no flicker")
        XCTAssertEqual(store.pendingMessage?.state, .sending)
        XCTAssertNil(store.pendingMessage?.errorDescription)
    }

    func test_clearPending_dropsSlot() {
        let store = SessionChatStore(sessionId: UUID(), sdkOnly: true)
        store.injectPending(text: "clear test")
        XCTAssertNotNil(store.pendingMessage)

        store.clearPending()

        XCTAssertNil(store.pendingMessage)
    }

    func test_perLineIngestTasksAreRemovedAfterCompletion() async {
        let store = SessionChatStore(sessionId: UUID(), sdkOnly: true)
        let task = Task<Void, Never> {}

        store.trackPerLineIngestTaskForTesting(task)
        XCTAssertEqual(store.perLineIngestTaskCountForTesting, 1)
        await task.value

        for _ in 0..<20 where store.perLineIngestTaskCountForTesting > 0 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(store.perLineIngestTaskCountForTesting, 0)
    }

    /// Offline queue accumulates pendings while the daemon is unreachable
    /// and drains FIFO on the next successful send.
    func test_offlineQueue_capturesPendingsForReplay() {
        let store = SessionChatStore(sessionId: UUID(), sdkOnly: true)

        store.injectPending(text: "first while offline")
        store.markPendingQueuedOffline(error: "daemon offline")
        XCTAssertEqual(store.pendingMessage?.state, .queuedOffline)
        XCTAssertEqual(store.queuedPendingMessages.count, 1)

        store.injectPending(text: "second while offline")
        store.markPendingQueuedOffline(error: "daemon offline")
        XCTAssertEqual(store.queuedPendingMessages.count, 2)

        let drained = store.dequeueOfflineQueue()
        XCTAssertEqual(drained.map(\.body), ["first while offline", "second while offline"])
        XCTAssertTrue(store.queuedPendingMessages.isEmpty)
    }

    /// Offline queue is capped — pendings beyond the limit surface as
    /// `.failed` so the user knows the buffer is full (not silently
    /// dropped).
    func test_offlineQueue_capExceeded_surfacesFailed() {
        let store = SessionChatStore(sessionId: UUID(), sdkOnly: true)
        for index in 0..<SessionChatStore.offlineQueueLimit {
            store.injectPending(text: "queue entry \(index)")
            store.markPendingQueuedOffline()
        }
        XCTAssertEqual(store.queuedPendingMessages.count, SessionChatStore.offlineQueueLimit)

        store.injectPending(text: "overflow")
        store.markPendingQueuedOffline()

        XCTAssertEqual(store.pendingMessage?.state, .failed,
                       "overflow must fail-loud rather than silently drop")
    }

    /// Reconcile clears the pending slot only when a user-text message
    /// with matching body appears in the snapshot. The match window is
    /// narrow (most-recent 4 user-texts) so a long transcript doesn't
    /// trigger a false match against an old message.
    func test_reconcilePending_clearsOnMatchingUserText() async throws {
        let store = SessionChatStore(sessionId: UUID(), sdkOnly: true)
        store.start()
        defer { store.stop() }
        let userMsg = ChatMessage(
            id: UUID().uuidString,
            kind: .userText,
            title: "You",
            body: "reconcile target",
            at: Date()
        )
        store.appendSDKMessages([userMsg])
        try await Task.sleep(nanoseconds: 200_000_000)

        store.injectPending(text: "reconcile target")
        XCTAssertNotNil(store.pendingMessage)

        store.reconcilePendingIfMatched()

        XCTAssertNil(store.pendingMessage,
                     "auto-reconcile should clear the pending slot on body match")
    }

    func test_reconcilePending_clearsAttachmentPromptWhenStagedPathDiffers() async throws {
        let store = SessionChatStore(sessionId: UUID(), sdkOnly: true)
        store.start()
        defer { store.stop() }

        store.injectPending(
            text: "@/Users/me/Desktop/Screenshots/SCR-20260614-pkny.png\nremove the % number",
            attachmentRefs: ["SCR-20260614-pkny.png"]
        )
        let userMsg = ChatMessage(
            id: UUID().uuidString,
            kind: .userText,
            title: "You",
            body: "@/repo/.clawdmeter-attachments/session/0A7AD7AC-2267-416F-B475-7FCB56D3DC7F.png\nremove the % number",
            at: Date()
        )

        store.appendSDKMessages([userMsg])
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertNil(
            store.pendingMessage,
            "Attachment sends must reconcile after staging rewrites the absolute @path."
        )
    }

    func test_reconcilePending_preservesUserMentionsWhenMatchingAttachmentPrompt() async throws {
        let store = SessionChatStore(sessionId: UUID(), sdkOnly: true)
        store.start()
        defer { store.stop() }

        store.injectPending(
            text: "@/Users/me/Desktop/Screenshots/SCR-20260614-pkny.png\n@/repo/apple/ClawdmeterMac/SessionsView.swift\nfix this",
            attachmentRefs: ["SCR-20260614-pkny.png"]
        )
        let userMsg = ChatMessage(
            id: UUID().uuidString,
            kind: .userText,
            title: "You",
            body: "@/repo/apple/ClawdmeterMac/SessionsView.swift\nfix this",
            at: Date()
        )

        store.appendSDKMessages([userMsg])
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertNil(
            store.pendingMessage,
            "Only absolute attachment @/path lines should be stripped; user @mentions remain part of the match."
        )
    }

    /// /review P1: a retry that re-hits the offline path must NOT
    /// double-enqueue the same pending — otherwise drain replays the
    /// message twice. Dedupe is by `PendingMessage.id`.
    func test_offlineQueue_retryReHittingOfflineDoesNotDoubleEnqueue() {
        let store = SessionChatStore(sessionId: UUID(), sdkOnly: true)
        store.injectPending(text: "flap test")
        store.markPendingQueuedOffline(error: "first")
        XCTAssertEqual(store.queuedPendingMessages.count, 1)
        let originalId = store.queuedPendingMessages.first?.id

        // Simulate retry: pending flips back to .sending, send fails
        // offline again, the composer re-marks queued.
        store.markPendingRetrying()
        store.markPendingQueuedOffline(error: "second")

        XCTAssertEqual(store.queuedPendingMessages.count, 1,
                       "retry re-hitting offline must dedupe by id, not append")
        XCTAssertEqual(store.queuedPendingMessages.first?.id, originalId)
        XCTAssertEqual(store.queuedPendingMessages.first?.errorDescription, "second",
                       "the queued entry should reflect the latest error copy")
    }

    /// /review P1: when the drain helper hits a failure mid-replay,
    /// the un-drained entries must be re-enqueued at the head so the
    /// next successful send picks them up. Exercises
    /// `requeueOfflinePending(_:)` directly — the composer's drain
    /// helper calls this with the failing entry + tail.
    func test_requeueOfflinePending_preservesUndrainedEntriesAtHead() {
        let store = SessionChatStore(sessionId: UUID(), sdkOnly: true)
        let first = OptimisticPendingMessage(body: "first", state: .queuedOffline)
        let second = OptimisticPendingMessage(body: "second", state: .queuedOffline)
        store.requeueOfflinePending([first, second])
        XCTAssertEqual(store.queuedPendingMessages.map(\.body), ["first", "second"])

        // Now re-queue a third at the head — emulates a partial drain
        // that succeeded once and failed on the next item.
        let third = OptimisticPendingMessage(body: "third", state: .queuedOffline)
        store.requeueOfflinePending([third])

        XCTAssertEqual(store.queuedPendingMessages.map(\.body), ["third", "first", "second"],
                       "requeue must prepend, preserving FIFO order of remaining items")
    }

    /// /review P1: requeue must respect the offline queue cap by
    /// trimming the OLDEST entries first (suffix-keep), so repeated
    /// daemon flaps don't grow the queue unbounded.
    func test_requeueOfflinePending_respectsCap_byTrimmingOldest() {
        let store = SessionChatStore(sessionId: UUID(), sdkOnly: true)
        // Fill the queue to the cap.
        let existing = (0..<SessionChatStore.offlineQueueLimit).map {
            OptimisticPendingMessage(body: "existing \($0)", state: .queuedOffline)
        }
        store.requeueOfflinePending(existing)
        XCTAssertEqual(store.queuedPendingMessages.count, SessionChatStore.offlineQueueLimit)

        // Add two more at the head — total = cap+2, expect the oldest
        // two (back of the queue) to be trimmed.
        let extras = [
            OptimisticPendingMessage(body: "new 0", state: .queuedOffline),
            OptimisticPendingMessage(body: "new 1", state: .queuedOffline),
        ]
        store.requeueOfflinePending(extras)

        XCTAssertEqual(store.queuedPendingMessages.count, SessionChatStore.offlineQueueLimit)
        // The two newest re-queued entries must survive — they were
        // prepended and the cap trims the oldest tail.
        XCTAssertEqual(store.queuedPendingMessages.first?.body, "new 0")
        XCTAssertEqual(store.queuedPendingMessages[1].body, "new 1")
    }

    /// D24 reinforcement: reconcile must NOT clear a `.failed` pending.
    /// If the daemon rejected the send, the user needs to see the chip
    /// regardless of whatever else is on screen.
    func test_reconcilePending_doesNotClearFailedSlot() async throws {
        let store = SessionChatStore(sessionId: UUID(), sdkOnly: true)
        store.start()
        defer { store.stop() }
        let userMsg = ChatMessage(
            id: UUID().uuidString,
            kind: .userText,
            title: "You",
            body: "matches pending",
            at: Date()
        )
        store.appendSDKMessages([userMsg])
        try await Task.sleep(nanoseconds: 200_000_000)

        store.injectPending(text: "matches pending")
        store.markPendingFailed(error: "rejected")

        store.reconcilePendingIfMatched()

        XCTAssertEqual(store.pendingMessage?.state, .failed,
                       "D24: failed pendings must survive any reconcile attempt")
    }
}

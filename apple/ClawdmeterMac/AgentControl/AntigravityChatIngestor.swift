import Foundation
import ClawdmeterShared
import OSLog

private let ingestorLogger = Logger(subsystem: "com.clawdmeter.mac", category: "AntigravityChatIngestor")

/// v0.9 — bridges the SQLite WAL conversation DB Antigravity 2 writes
/// for every agentapi session into a `SessionChatStore` so chat-subscribe
/// WS clients see Gemini chat items through the same uniform snapshot
/// pipeline as Claude (CLI), Codex (CLI + SDK).
///
/// Sibling of `CodexSDKEventIngestor`. Wraps an `AntigravityConversationDB`
/// (T6) subscription and emits one `ChatMessage` per emitted step row.
///
/// **Step-type mapping (validated against Antigravity 2.0.6 WAL DBs at
/// `~/.gemini/antigravity/conversations/<id>.db`):**
///   - 5, 7, 8, 9, 21, 132 → tool-call rows. `ConversationProtoParser.decode`
///     extracts `toolName` from the nested toolcall submessage; we render
///     a `.toolCall` summary with that name. The proto layout (toolcall
///     submessage at inner field 4 → name at field 2) is shared across
///     every tool step_type observed in production traces.
///   - 13 (legacy assistant_text in 2.0.0) → `.assistantText` placeholder.
///     No 2.0.6 trace we've inspected emits this; kept for back-compat
///     with older installs.
///   - everything else (14 init, 15 heartbeat, 23 status, 98 setup, 101
///     task signals, etc.) → `.meta` row.
///
/// **Known gap:** Antigravity 2.0.6's WAL doesn't carry Gemini's natural-
/// language chat reply as its own step type — agent runs surface as tool
/// traces. Pulling the prose response (if any) needs either an alternate
/// agentapi RPC channel or proto-schema reverse engineering on the inner
/// step payload at idx that immediately precedes turn-end. Tracked
/// separately; the WAL ingestor renders all observable activity in the
/// meantime.
///
/// **Turn-end detection:** the underlying `AntigravityConversationDB.subscribe()`
/// AsyncStream never naturally finishes (it stays open for the actor's
/// lifetime). We layer a quiescence watchdog on top: after the first step
/// arrives, if no new step lands within `quiescenceWindow` seconds we
/// flip to `.completed` and exit. Without this the session is stuck at
/// `.streaming` forever.
public actor AntigravityChatIngestor {

    /// Seconds of WAL silence (after the first step) that we treat as
    /// turn-end. Antigravity's run loop emits step_type=15 heartbeats
    /// roughly every second while the agent is active, so 6s is well
    /// past the heartbeat cadence but short enough that the iOS smoke
    /// test's 180s poll budget completes promptly. Tunable here only.
    private static let quiescenceWindow: TimeInterval = 6

    private let sessionId: UUID
    private let conversationId: UUID
    private let dbURL: URL
    private let store: SessionChatStore
    private var subscriptionTask: Task<Void, Never>?
    private var lastSeenIdx: Int = -1
    /// Wall-clock of the most recent step we forwarded. Watchdog flips
    /// the turn to .completed when `now - lastStepAt > quiescenceWindow`.
    private var lastStepAt: Date?

    public init(
        sessionId: UUID,
        conversationId: UUID,
        dbURL: URL,
        store: SessionChatStore
    ) {
        self.sessionId = sessionId
        self.conversationId = conversationId
        self.dbURL = dbURL
        self.store = store
    }

    /// Start a background task that: (0) waits for the SQLite DB file to
    /// exist (Antigravity creates it on first WAL write — may lag the
    /// daemon's `new-conversation` reply by a few hundred ms), (1)
    /// drains all existing steps once to populate history, (2)
    /// subscribes to new steps and forwards them as ChatMessages.
    /// Idempotent — re-call after `stop()`.
    public func start() {
        guard subscriptionTask == nil else { return }
        ingestorLogger.info("AntigravityChatIngestor start session=\(self.sessionId.uuidString, privacy: .public) conv=\(self.conversationId.uuidString, privacy: .public)")
        let conversationIdLocal = self.conversationId
        let storeLocal = self.store
        let dbURLLocal = self.dbURL
        subscriptionTask = Task {
            // (0) wait for the file. Antigravity writes the WAL DB on
            // first commit, which can lag new-conversation by a few
            // hundred ms. Cap at ~30s total (60 * 500ms) so we don't
            // hang an evict-recreate cycle forever.
            var db: AntigravityConversationDB? = nil
            for _ in 0..<60 {
                if Task.isCancelled { return }
                if FileManager.default.fileExists(atPath: dbURLLocal.path) {
                    do {
                        db = try AntigravityConversationDB(dbURL: dbURLLocal)
                        break
                    } catch {
                        ingestorLogger.warning("agentapi DB open failed: \(error.localizedDescription, privacy: .public) — retry in 500ms")
                    }
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            guard let openedDB = db else {
                ingestorLogger.warning("agentapi DB never appeared for conv=\(conversationIdLocal.uuidString, privacy: .public) — giving up")
                return
            }
            // (1) backfill history. We don't flip the turn state during
            // backfill — these are historical rows, not a live turn.
            do {
                let initial = try await openedDB.allSteps()
                for step in initial {
                    await Self.forwardStep(
                        step,
                        conversationId: conversationIdLocal,
                        store: storeLocal
                    )
                }
                if let last = initial.last {
                    await self.setLastSeenIdx(last.idx)
                }
            } catch {
                ingestorLogger.warning("agentapi allSteps backfill failed: \(error.localizedDescription, privacy: .public)")
            }
            // (2) tail incremental + watchdog. The underlying AsyncStream
            // never finishes on its own — Antigravity's WAL stays open
            // for the conversation's lifetime. We run two cooperating
            // tasks: the consumer drives `.streaming` and forwards each
            // step + updates `lastStepAt`; the watchdog polls that
            // timestamp and ends the group when the WAL goes quiet past
            // `quiescenceWindow`. Whichever finishes first cancels the
            // other via TaskGroup semantics. On clean exit (not
            // user-cancelled) we flip to `.completed`; on cancellation,
            // SessionInterruptDispatcher owns the `.interrupted` flip
            // and we don't override.
            let stream = await openedDB.subscribe()
            await withTaskGroup(of: TurnEndReason.self) { group in
                let ingestor = self
                group.addTask {
                    for await step in stream {
                        if Task.isCancelled { return .consumerCancelled }
                        await Self.flipToStreaming(store: storeLocal)
                        await Self.forwardStep(
                            step,
                            conversationId: conversationIdLocal,
                            store: storeLocal
                        )
                        await ingestor.recordStepArrived()
                    }
                    return .streamClosed
                }
                group.addTask {
                    // Tick every second; cheap, and the watchdog cap is
                    // 6s so granularity is fine. Returns once quiescent.
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        if Task.isCancelled { return .consumerCancelled }
                        if await ingestor.isQuiescent() {
                            return .quiescent
                        }
                    }
                    return .consumerCancelled
                }
                let reason = await group.next() ?? .consumerCancelled
                group.cancelAll()
                if reason != .consumerCancelled {
                    await Self.flipToCompleted(store: storeLocal)
                }
            }
        }
    }

    /// Why the ingestion task group ended. Drives the turn-end flip.
    private enum TurnEndReason: Sendable {
        /// `AntigravityConversationDB.subscribe()` actually closed —
        /// e.g. the DB actor deallocated. Rare in production but the
        /// natural happy-path the original v0.9 design assumed.
        case streamClosed
        /// Quiescence watchdog observed no new steps for >quiescenceWindow.
        /// This is the path 2.0.6 chat sessions actually take.
        case quiescent
        /// `stop()` cancelled us; SessionInterruptDispatcher will paint
        /// the right end state.
        case consumerCancelled
    }

    /// Called by the consumer task each time a step is forwarded.
    /// Updates the watchdog's reference clock so quiescence resets.
    fileprivate func recordStepArrived() {
        lastStepAt = Date()
    }

    /// Quiescence predicate: true iff we have seen at least one step AND
    /// the most recent one is older than `quiescenceWindow`. The pre-
    /// first-step branch returns false so that a slow-to-start WAL
    /// (Antigravity takes ~1-2s to commit the initial rows) doesn't fire
    /// the watchdog before any work has happened.
    fileprivate func isQuiescent() -> Bool {
        guard let lastStepAt else { return false }
        return Date().timeIntervalSince(lastStepAt) > Self.quiescenceWindow
    }

    /// Cancel the subscription. The store + DB stay alive — only this
    /// ingestor's forwarding loop ends.
    public func stop() {
        subscriptionTask?.cancel()
        subscriptionTask = nil
    }

    /// MainActor hop helpers — `SessionChatStore.setCurrentTurnState`
    /// is `@MainActor`-isolated and the subscribe loop runs on the
    /// ingestor actor. Pulled out as `static` so the @MainActor
    /// annotation closes cleanly without crossing the actor boundary
    /// in the call site.
    @MainActor
    private static func flipToStreaming(store: SessionChatStore) {
        store.setCurrentTurnState(.streaming)
    }

    @MainActor
    private static func flipToCompleted(store: SessionChatStore) {
        store.setCurrentTurnState(.completed)
    }

    private func setLastSeenIdx(_ idx: Int) {
        lastSeenIdx = max(lastSeenIdx, idx)
    }

    /// Translate one DB row into a ChatMessage and hand it to the store.
    /// `@MainActor` because SessionChatStore.appendSDKMessages hops main.
    @MainActor
    private static func forwardStep(
        _ step: AntigravityConversationStep,
        conversationId: UUID,
        store: SessionChatStore
    ) {
        let decoded = ConversationProtoParser.decode(step.stepPayload)
        let stepType = Int(decoded.stepType ?? UInt64(step.stepType))
        let id = "agy-\(conversationId.uuidString)-\(step.idx)"
        let at = Date()  // DB doesn't carry per-row timestamps; staging.dedup keys on id

        // 2.0.6 routes Gemini's natural-language replies through
        // `[Message]` blocks embedded in step_type=101 payloads. Surface
        // any agent-sender block as `.assistantText`, drop the user-prompt
        // echo (sender=system; the composer already showed it), and skip
        // the per-task completion noise. Multiple message blocks in one
        // step row each get their own chat row.
        var messages: [ChatMessage] = []
        for (offset, block) in decoded.messages.enumerated() {
            switch block.senderKind {
            case .agent(let senderId):
                messages.append(ChatMessage(
                    id: "\(id)-msg-\(offset)",
                    kind: .assistantText,
                    title: "Gemini",
                    body: block.content,
                    at: at,
                    isError: false
                ))
                _ = senderId
            case .system:
                continue  // user-prompt echo; composer owns its render
            case .taskCompletion:
                continue  // internal agent signal; not chat-worthy
            }
        }
        if !messages.isEmpty {
            store.appendSDKMessages(messages, at: at)
            return
        }

        let message: ChatMessage
        switch stepType {
        case 13:
            // 2.0.0 assistant_text. 2.0.6 doesn't emit this — kept for
            // back-compat with older Antigravity installs that someone
            // might still be running. Body decoding is still TODO; for
            // now we render the placeholder so at least the UI sees an
            // assistant turn.
            message = ChatMessage(
                id: id,
                kind: .assistantText,
                title: "Gemini",
                body: "(Gemini message — open Antigravity 2 to read full text)",
                at: at
            )
        case 5, 7, 8, 9, 21, 132:
            // Tool calls. 2.0.6 disperses tool invocations across these
            // step_types (5=write_to_file/replace_file_content, 7=grep_search,
            // 8=view_file, 9=list_dir, 21=run_command, 132=list_permissions/
            // manage_task and other agent-control tools). All share the
            // same nested toolcall submessage layout, so the parser's
            // toolName extraction works uniformly — verified against
            // live WAL traces. We surface them all as `.toolCall` rather
            // than synthesizing a `.toolResult` because 2.0.6 packs both
            // request args + completion status into a single row (no
            // separate response step the way 2.0.0 had).
            let toolName = decoded.toolName ?? "tool"
            message = ChatMessage(
                id: id,
                kind: .toolCall,
                title: toolName,
                body: "Running \(toolName)…",
                at: at
            )
        default:
            // 14 init, 15 heartbeat, 23 status, 98 setup, 101 task
            // signals, etc. — agent infrastructure, not user-facing
            // conversation content. Surfaced as low-emphasis meta rows
            // so triage can see them in the snapshot without dominating
            // the UI.
            message = ChatMessage(
                id: id,
                kind: .meta,
                title: "agy",
                body: "step_type=\(stepType) status=\(step.status)",
                at: at
            )
        }
        store.appendSDKMessages([message], at: at)
    }
}

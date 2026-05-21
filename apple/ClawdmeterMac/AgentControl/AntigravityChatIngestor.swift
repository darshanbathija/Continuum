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
/// (T6) subscription and emits one `ChatMessage` per emitted step row:
///   - step_type 13 (assistant_text) → `.assistantText` message
///   - step_type 8/9  (tool_call_request / tool_call_response) → `.toolCall`
///     summary with the parsed `toolName` (proto decode by
///     `ConversationProtoParser.decode`)
///   - other step types → `.meta` placeholder
///
/// **v0.9 limitation (TODO v0.9.x):** assistant_text body is currently a
/// placeholder. The ConversationProtoParser only extracts toolCallId +
/// toolName from `step_payload` — the assistant message body lives at a
/// deeper proto nesting we don't yet decode. The user sees:
///   - their own message immediately (echoed via `appendUserMessage`)
///   - a "Gemini replied…" assistant marker as soon as the WAL fires
///   - tool runs by name as Gemini orchestrates
///
/// Extending the parser to extract assistant text is the next polish
/// pass; the SDK ingestor + iOS surface already round-trip through this
/// pipe so the polish is one-file-and-done.
public actor AntigravityChatIngestor {

    private let sessionId: UUID
    private let conversationId: UUID
    private let dbURL: URL
    private let store: SessionChatStore
    private var subscriptionTask: Task<Void, Never>?
    private var lastSeenIdx: Int = -1

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
            // (1) backfill history
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
            // (2) tail incremental
            let stream = await openedDB.subscribe()
            for await step in stream {
                if Task.isCancelled { break }
                await Self.forwardStep(
                    step,
                    conversationId: conversationIdLocal,
                    store: storeLocal
                )
            }
        }
    }

    /// Cancel the subscription. The store + DB stay alive — only this
    /// ingestor's forwarding loop ends.
    public func stop() {
        subscriptionTask?.cancel()
        subscriptionTask = nil
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
        let message: ChatMessage
        switch stepType {
        case 13:
            // assistant_text — body extraction is v0.9.x polish; for now
            // mark the turn so the UI shows progress.
            message = ChatMessage(
                id: id,
                kind: .assistantText,
                title: "Gemini",
                body: "(Gemini message — open Antigravity 2 to read full text)",
                at: at
            )
        case 8, 9:
            // tool_call_request / tool_call_response — surface the
            // tool name we DID parse out.
            let toolName = decoded.toolName ?? "tool"
            let kind: ChatMessage.Kind = (stepType == 9) ? .toolResult : .toolCall
            message = ChatMessage(
                id: id,
                kind: kind,
                title: toolName,
                body: stepType == 9 ? "→ result" : "Running \(toolName)…",
                at: at
            )
        default:
            // other step_types (planning, metadata, sub-trajectory
            // headers, etc.) surface as low-emphasis meta rows.
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

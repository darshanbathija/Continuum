// v0.7.4: subscribe to CodexSubscriptionRelay events for a session and
// translate the SDK's typed stream events into ChatMessage records that
// feed SessionChatStore via `appendSDKMessages`. Result: SDK observation
// flows into the same `chat-subscribe` WebSocket pipeline that already
// carries Claude + Codex CLI chat — iOS gets SDK-observed turns for free.
//
// Lifecycle:
//   - `start()` opens a Combine sink against `relay.subscribe(sessionId:)`.
//   - `stop()` cancels the sink. The underlying sidecar lives on; another
//     consumer (WS channel) may still be subscribed.

import Foundation
import Combine
import OSLog
import ClawdmeterShared

private let ingestorLogger = Logger(
    subsystem: "com.clawdmeter.mac",
    category: "CodexSDKEventIngestor"
)

@MainActor
public final class CodexSDKEventIngestor {

    private let sessionId: UUID
    private weak var store: SessionChatStore?
    private let relay: CodexSubscriptionRelay
    private var cancellable: AnyCancellable?
    /// v0.8 Phase 4.5: SDK chat persists the threadId on the AgentSession
    /// for resume-after-evict (NEW-T13). The daemon's chat handler passes
    /// a closure that calls `registry.setCodexChatThreadId(...)` once the
    /// first `thread.started` event arrives. Nil for non-chat consumers.
    private let onThreadStarted: ((String) -> Void)?
    /// True once we've already fired `onThreadStarted` for this session —
    /// subsequent `thread.started` (shouldn't happen mid-session, but
    /// defense) won't re-persist.
    private var threadStartedFired = false

    public init(sessionId: UUID,
                store: SessionChatStore,
                relay: CodexSubscriptionRelay = .shared,
                onThreadStarted: ((String) -> Void)? = nil) {
        self.sessionId = sessionId
        self.store = store
        self.relay = relay
        self.onThreadStarted = onThreadStarted
    }

    public func start() {
        guard cancellable == nil else { return }
        ingestorLogger.info("ingestor.start session=\(self.sessionId.uuidString, privacy: .public)")
        cancellable = relay.subscribe(sessionId: sessionId)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.handle(event: event)
            }
    }

    public func stop() {
        cancellable?.cancel()
        cancellable = nil
    }

    // MARK: - Event handling

    private func handle(event: CodexRelayEvent) {
        guard let store = store else { return }
        let raw = event.rawDict()
        switch event.kind {
        case .item:
            // v0.23 T4: first item content of a turn flips us into
            // `.streaming`. The transition is idempotent on the store
            // side, so re-firing on every item is cheap.
            store.setCurrentTurnState(.streaming)
            handleItem(raw: raw, at: event.receivedAt, store: store)
        case .turnCompleted:
            handleTurnCompleted(raw: raw, at: event.receivedAt, store: store)
            // v0.23 T4: provider's natural end-of-turn marker — flips
            // the V2 status strip stopwatch + restores the Send button.
            store.setCurrentTurnState(.completed)
        case .turnFailed:
            let body = (raw["error"] as? [String: Any])?["message"] as? String
                ?? "Turn failed"
            appendMeta(store: store,
                       id: "codex-sdk-turn-failed-\(event.receivedAt.timeIntervalSince1970)",
                       title: "Turn failed",
                       body: body,
                       at: event.receivedAt,
                       isError: true)
            // v0.23 T4: failed turn still terminates the lifecycle.
            // Treat as `.completed` for UI purposes (Stop→Send flips,
            // stopwatch clamps); the appended meta row makes the
            // failure visible.
            store.setCurrentTurnState(.completed)
        case .error:
            let body = raw["message"] as? String ?? "Stream error"
            appendMeta(store: store,
                       id: "codex-sdk-error-\(event.receivedAt.timeIntervalSince1970)",
                       title: "Codex error",
                       body: body,
                       at: event.receivedAt,
                       isError: true)
            // v0.23 T4: same logic as turnFailed — terminate so the UI
            // doesn't spin forever waiting for a turn that errored out.
            store.setCurrentTurnState(.completed)
        case .threadStarted:
            // v0.8 Phase 4.5: surface the threadId to the SDK chat session
            // record so resume-after-evict knows which thread to reconnect.
            if !threadStartedFired, let threadId = event.threadId {
                threadStartedFired = true
                onThreadStarted?(threadId)
            }
        case .turnStarted:
            // v0.23 T4: SDK explicit turn-start marker. Earlier than
            // the first `.item` event, so it's the most accurate
            // transition into `.streaming`.
            store.setCurrentTurnState(.streaming)
        case .streamStarted, .streamDone, .streamError,
             .observerReady, .unknown:
            // Other lifecycle markers — don't surface as chat.
            break
        }
    }

    /// Map an SDK item event (started/updated/completed — relay collapses
    /// them to `.item`) into a ChatMessage. The SDK emits these inside a
    /// `stream_event` envelope; the relay's `classify` already extracted
    /// the inner event, so `raw` here is the item payload directly.
    private func handleItem(raw: [String: Any], at timestamp: Date, store: SessionChatStore) {
        guard let item = raw["item"] as? [String: Any] else { return }
        // v0.8 QA: the SDK emits `item.type` (e.g. "agent_message"),
        // not `item.item_type` — the earlier code missed every SDK item
        // event and dropped all assistant responses on the floor. Read
        // `type` first; fall back to `item_type` only as defense for any
        // future SDK rename.
        let itemType = (item["type"] as? String)
            ?? (item["item_type"] as? String)
            ?? ""
        let itemId = item["id"] as? String
            ?? "codex-sdk-item-\(timestamp.timeIntervalSince1970)"

        switch itemType {
        case "agent_message":
            let text = (item["text"] as? String) ?? ""
            guard !text.isEmpty else { return }
            store.appendSDKMessages([
                ChatMessage(id: itemId,
                            kind: .assistantText,
                            title: "Codex",
                            body: text,
                            at: timestamp)
            ], at: timestamp)
        case "reasoning":
            let text = (item["text"] as? String) ?? ""
            guard !text.isEmpty else { return }
            store.appendSDKMessages([
                ChatMessage(id: "\(itemId)-reasoning",
                            kind: .meta,
                            title: "Reasoning",
                            body: text,
                            at: timestamp)
            ], at: timestamp)
        case "command_execution":
            let cmd = (item["command"] as? String) ?? "(unknown command)"
            let status = (item["status"] as? String) ?? ""
            let exitCode = item["exit_code"] as? Int
            let stdout = (item["aggregated_output"] as? String) ?? ""

            // tool_call first (the command itself)
            store.appendSDKMessages([
                ChatMessage(id: "\(itemId)-call",
                            kind: .toolCall,
                            title: "Bash",
                            body: cmd,
                            detail: cmd,
                            at: timestamp,
                            bashResult: BashResult(command: cmd))
            ], at: timestamp)

            // tool_result on completion
            if status == "completed" || status == "failed" {
                let resultHeader: String
                if let exitCode {
                    resultHeader = "exit=\(exitCode)"
                } else if status == "failed" {
                    resultHeader = "failed"
                } else {
                    resultHeader = "done"
                }
                let body = stdout.isEmpty ? resultHeader : "\(resultHeader)\n\(stdout)"
                store.appendSDKMessages([
                    ChatMessage(id: "\(itemId)-result",
                                kind: .toolResult,
                                title: "Bash",
                                body: body,
                                at: timestamp,
                                isError: status == "failed",
                                bashResult: BashResult(
                                    command: cmd,
                                    exitCode: exitCode,
                                    stdout: stdout.isEmpty ? nil : stdout
                                ))
                ], at: timestamp)
            }
        case "file_change":
            let path = (item["path"] as? String) ?? "?"
            let action = (item["action"] as? String) ?? "changed"
            appendMeta(store: store,
                       id: "\(itemId)-file",
                       title: "File \(action)",
                       body: path,
                       at: timestamp)
        case "mcp_tool_call":
            let server = (item["server"] as? String) ?? "mcp"
            let tool = (item["tool"] as? String) ?? "?"
            let status = (item["status"] as? String) ?? ""
            let label = "MCP: \(server).\(tool)"
            store.appendSDKMessages([
                ChatMessage(id: "\(itemId)-mcp",
                            kind: .toolCall,
                            title: "MCP",
                            body: status.isEmpty ? label : "\(label) (\(status))",
                            at: timestamp)
            ], at: timestamp)
        case "web_search":
            let query = (item["query"] as? String) ?? ""
            appendMeta(store: store,
                       id: "\(itemId)-web",
                       title: "Web search",
                       body: query.isEmpty ? "(no query)" : query,
                       at: timestamp)
        case "todo_list":
            // v0.7.8: parse the structured todos so the Plan surfaces
            // (Mac CodexPlanPane, iOS CodexPlanView, Watch task
            // complication) can render the full list — the previous
            // implementation dropped the items and surfaced only a
            // "Todo list updated, N items" meta row.
            let rawTodos = (item["todos"] as? [[String: Any]]) ?? []
            let parsed: [CodexTodoItem] = rawTodos.enumerated().compactMap { (idx, raw) in
                let text = (raw["text"] as? String) ?? (raw["title"] as? String) ?? ""
                guard !text.isEmpty else { return nil }
                let status = (raw["status"] as? String) ?? "pending"
                let id = (raw["id"] as? String) ?? "\(itemId)-todo-\(idx)"
                return CodexTodoItem(id: id, text: text, status: status)
            }
            store.setCodexTodos(parsed)
            // Also keep a lightweight meta entry in the chat for
            // scrollback continuity — the Plan surfaces are the
            // primary read path, this is just a breadcrumb.
            appendMeta(store: store,
                       id: "\(itemId)-todos",
                       title: "Todo list updated",
                       body: "\(parsed.count) item\(parsed.count == 1 ? "" : "s")",
                       at: timestamp)
        case "error":
            let body = (item["message"] as? String) ?? "Tool error"
            appendMeta(store: store,
                       id: "\(itemId)-err",
                       title: "Tool error",
                       body: body,
                       at: timestamp,
                       isError: true)
        default:
            // Unknown item type — surface as meta so we don't lose it.
            ingestorLogger.debug("ingestor: unknown item_type=\(itemType, privacy: .public)")
        }
    }

    /// `turn.completed` carries `usage` totals. Forward them as a zero-message
    /// staging tick so the cost-ticker picks up the delta. (The SDK emits
    /// totals not deltas, so we'd need to track previous totals to compute a
    /// proper delta — for now, forward as input/output and let the cumulative
    /// totals in ChatSnapshot grow monotonically. Accurate enough for the
    /// composer's cost banner; a follow-up can switch to delta-tracking.)
    private func handleTurnCompleted(raw: [String: Any], at timestamp: Date, store: SessionChatStore) {
        guard let usage = raw["usage"] as? [String: Any] else { return }
        let input = usage["input_tokens"] as? Int ?? 0
        let cachedInput = usage["cached_input_tokens"] as? Int ?? 0
        let output = usage["output_tokens"] as? Int ?? 0
        store.appendSDKMessages(
            [],
            at: timestamp,
            deltaInputTokens: input,
            deltaOutputTokens: output,
            deltaCacheReadTokens: cachedInput
        )
    }

    private func appendMeta(store: SessionChatStore,
                            id: String,
                            title: String,
                            body: String,
                            at timestamp: Date,
                            isError: Bool = false) {
        store.appendSDKMessages([
            ChatMessage(id: id,
                        kind: .meta,
                        title: title,
                        body: body,
                        at: timestamp,
                        isError: isError)
        ], at: timestamp)
    }
}

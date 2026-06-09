// OpenCode SSE adapter — subscribes to the singleton `opencode serve`
// /event stream and translates incoming events into the AgentEventStream
// shape that AgentSessionRegistry + chat-subscribe consumers already
// know how to render.
//
// Architecture (PR #30):
//   1. Consume `GET /event` on the shared OpencodeProcessManager port.
//      The stream is text/event-stream; each event is a JSON object
//      with fields { type, properties }.
//   2. Maintain a bi-directional UUID map: opencode's session id ↔
//      Clawdmeter's AgentSession.id. We can't reuse opencode's id
//      directly because the registry indexes everything by UUID.
//   3. Reconnect on disconnect with exponential backoff. On reconnect,
//      replay any events the server buffered while we were offline (the
//      `Last-Event-ID` header). Newer events arrive in order — the
//      monotonic seq on AgentEventStream keeps the timeline consistent.
//
// Event mapping (current minimal cut — PR #30 covers the spawn loop;
// full event taxonomy lands in the OpencodeUsageMapper PR):
//   - `session.created` → registry.create(...)
//   - `message.added` with role=assistant → registry chat-stream append
//   - `usage` → forwarded to OpencodeUsageMapper (PR #31)
//   - `session.error` → AgentEventStream .sessionDegraded
//   - everything else → logged + ignored (forward-compat: opencode
//     ships ~weekly minor versions and we don't want to crash on a
//     new event type).
//
// Wire shape (per the opencode TypeScript types we mirror, captured
// 2026-05-22 against opencode v1.15.x — versions earlier than 1.10
// have a different event envelope and aren't supported):
//
//   data: {"type":"session.created","properties":{"id":"opc_abc","title":"…"}}\n\n
//   data: {"type":"message.added","properties":{"sessionID":"opc_abc","message":{"role":"assistant","content":[…]}}}\n\n
//
// opencode ≥1.16 retired `message.added` and streams turns as (captured
// 2026-06-10 against a live opencode v1.16.2 serve):
//
//   message.updated       — {sessionID, info:{id, role, time:{created, completed?},
//                            tokens?, modelID?, finish?}} message lifecycle; the
//                            assistant info gains `time.completed` + `tokens` when done.
//   message.part.updated  — {sessionID, part:{id, messageID, type:"text"|"reasoning"|
//                            "step-start", text?}} cumulative part snapshot.
//   message.part.delta    — {sessionID, messageID, partID, field:"text", delta}
//                            incremental text for BOTH text and reasoning parts.
//   session.status        — {sessionID, status:{type:"busy"|"idle"}} turn activity.
//   session.idle          — {sessionID} terminal turn marker.
//
// Without the ≥1.16 handlers below, a live 1.16 serve streams an entire
// reply that the adapter logs as "unhandled event type" — the Code tab
// composer stays on Stop forever and the reply never renders. The legacy
// handlers stay untouched for older serves.
//
// The properties payload is opaque to this file — we hand the raw JSON
// dict to the registry/stream rather than reifying every opencode
// schema into a Swift struct. That keeps the adapter resilient to
// opencode's frequent point-releases (per the plan: "pin to a tested
// minor (e.g. v1.15.x); bump deliberately").

import Foundation
import OSLog
import ClawdmeterShared

@MainActor
public final class OpencodeSSEAdapter {

    public static let shared = OpencodeSSEAdapter()

    private let logger = Logger(subsystem: "com.clawdmeter.mac", category: "OpencodeSSEAdapter")

    /// Live-verify debug trace. os_log debug lines are not persisted from
    /// xctest hosts, which made the 2026-06-10 live SSE failure opaque —
    /// this prints stream lifecycle + event TYPES (never bodies/tokens)
    /// to stderr only when the live-verify gate is already set.
    private static let liveDebugEnabled =
        ProcessInfo.processInfo.environment["CLAWDMETER_LIVE_VERIFY"] == "1"
    nonisolated private static func liveDebug(_ message: @autoclosure () -> String) {
        guard liveDebugEnabled else { return }
        FileHandle.standardError.write(Data("[opencode-sse] \(message())\n".utf8))
    }

    /// Bi-directional UUID map between opencode session ids (opaque
    /// strings the server hands out — typically "ses_<base32>" or
    /// similar; we don't parse them) and Clawdmeter's AgentSession.id.
    /// Populated on session.created events; read by the registry when
    /// it needs to route an outgoing prompt to the right opencode
    /// session-id over the prompt POST.
    public private(set) var sessionMap: BidirectionalMap = .init()

    /// v0.23.2: chat-store lookup for routing `message.added` events
    /// into the per-session SessionChatStore (so chat-subscribe WS
    /// streams them to iOS/Mac). AppRuntime injects this at startup
    /// to break the circular dependency between the adapter and the
    /// registry — without it, `handleMessageAdded` falls back to
    /// just emitting a snapshot AgentEventStream signal as before.
    public var chatStoreAccessor: (@MainActor (UUID) -> SessionChatStore?)?

    /// v0.23.2: convenience accessor for `AgentControlServer` — given
    /// our Clawdmeter session UUID, return the opencode session id
    /// the server hands back in the `session.created` event. Returns
    /// nil for sessions that haven't been registered yet (the SSE
    /// stream hasn't observed their creation).
    public func opencodeSessionId(for clawdmeterID: UUID) -> String? {
        sessionMap.clawdmeterToOpencode[clawdmeterID]
    }

    /// PR #32: per-session repo lookup. The opencode `usage` event
    /// doesn't carry the cwd, but the Clawdmeter-side session was
    /// created against a specific repo path; we stash that here at
    /// register time so `handleUsage` can tag the UsageRecord with
    /// the right repo for analytics bucketing.
    private var repoBySessionID: [String: String] = [:]

    /// opencode ≥1.16 streaming state. Replies arrive as per-part
    /// cumulative snapshots (`message.part.updated`) interleaved with
    /// incremental deltas (`message.part.delta`), so we keep one text
    /// buffer per part and re-project the joined assistant message on
    /// every change. Role/kind maps gate projection: only `text` parts
    /// of `assistant` messages become chat rows (reasoning/step parts
    /// only drive the streaming indicator, and user parts are skipped
    /// because the daemon already echoed the prompt locally at send).
    private var messageRoleByID: [String: String] = [:]
    private var messageOpencodeSessionByID: [String: String] = [:]
    private var partKindByID: [String: String] = [:]
    private var partTextByID: [String: String] = [:]
    private var partOrderByMessageID: [String: [String]] = [:]
    /// Runaway guard: a stream that never completes its messages (or an
    /// out-of-band serve we observe but never registered) must not grow
    /// these maps forever. Crossing the cap drops all buffered part
    /// state — worst case the in-flight reply re-projects from the next
    /// cumulative part snapshot.
    private static let maxBufferedParts = 4096

    /// Reconnect attempt counters, keyed by stream directory ("" is the
    /// unscoped serve-cwd stream). Per-directory so one dead project
    /// stream cannot exhaust the budget for every other session.
    private var reconnectCounts: [String: Int] = [:]
    private static let maxReconnects = 10

    /// Active streaming tasks keyed by directory. opencode ≥1.16 scopes
    /// `/event` to one project directory per connection — an unscoped
    /// subscription only ever sees the serve process's own cwd project,
    /// so every registered session directory needs its own stream.
    /// Cancelled on `stop()`.
    private var streamTasksByDirectory: [String: Task<Void, Never>] = [:]

    /// Directories in registration order (oldest first) for the LRU cap.
    private var streamDirectoryOrder: [String] = []

    /// Every Continuum chat/code session gets its own cwd, so an
    /// unbounded app run would otherwise accumulate one idle SSE
    /// connection per historical session. Oldest streams die first;
    /// an idle old session that wakes up re-registers on its next send.
    private static let maxDirectoryStreams = 32

    /// True between start() and stop(): newly registered directories
    /// spin their stream up immediately instead of waiting for restart.
    private var streamingActive = false

    /// Last event id we processed per directory — sent on reconnect as
    /// Last-Event-ID so the server can resume where we dropped off.
    private var lastEventIds: [String: String] = [:]

    /// Recently dispatched envelope ids. Streams for nested/duplicate
    /// directories can overlap; replaying a completion event would
    /// double-count its token deltas, so dispatch dedupes on the
    /// envelope id opencode stamps on every event.
    private var recentEventIds: [String] = []
    private var recentEventIdSet: Set<String> = []
    private static let maxRecentEventIds = 512

    // MARK: - Public API

    /// Start the SSE subscriptions. Returns immediately; each stream
    /// runs in its own task. Safe to call multiple times — old tasks
    /// are cancelled before new ones start (used on restart-after-
    /// crash from OpencodeProcessManager). Starts the unscoped stream
    /// (serve-cwd project) plus one scoped stream per directory already
    /// registered; later `register` calls add their directory's stream
    /// on the fly.
    public func start() {
        for task in streamTasksByDirectory.values { task.cancel() }
        streamTasksByDirectory.removeAll()
        streamDirectoryOrder.removeAll()
        streamingActive = true
        ensureStreamRunning(directory: "")
        for directory in Set(repoBySessionID.values) {
            ensureStreamRunning(directory: directory)
        }
    }

    /// Cancel the streams + clear in-flight state. Called from
    /// OpencodeProcessManager.stop() and from AppRuntime teardown.
    public func stop() {
        streamingActive = false
        for task in streamTasksByDirectory.values { task.cancel() }
        streamTasksByDirectory.removeAll()
        streamDirectoryOrder.removeAll()
        reconnectCounts.removeAll()
        lastEventIds.removeAll()
        recentEventIds.removeAll()
        recentEventIdSet.removeAll()
        sessionMap.removeAll()
        repoBySessionID.removeAll()
        messageRoleByID.removeAll()
        messageOpencodeSessionByID.removeAll()
        partKindByID.removeAll()
        partTextByID.removeAll()
        partOrderByMessageID.removeAll()
        logger.info("opencode SSE adapter stopped")
    }

    /// Spin up (or keep) the SSE stream for one directory. Applies the
    /// LRU cap: registering stream N+1 cancels the oldest directory's
    /// stream first.
    private func ensureStreamRunning(directory: String) {
        guard streamingActive else { return }
        if let existing = streamTasksByDirectory[directory], !existing.isCancelled {
            return
        }
        while streamDirectoryOrder.count >= Self.maxDirectoryStreams,
              let oldest = streamDirectoryOrder.first {
            logger.info("opencode SSE: stream cap reached; closing oldest directory stream")
            streamTasksByDirectory[oldest]?.cancel()
            streamTasksByDirectory.removeValue(forKey: oldest)
            streamDirectoryOrder.removeFirst()
        }
        streamDirectoryOrder.removeAll { $0 == directory }
        streamDirectoryOrder.append(directory)
        Self.liveDebug("starting stream for directory=\(directory.isEmpty ? "<unscoped>" : directory)")
        streamTasksByDirectory[directory] = Task { [weak self] in
            await self?.runStreamLoop(directory: directory)
        }
    }

    /// Register a Clawdmeter session id → opencode session id mapping.
    /// Called when AgentControlServer creates an opencode-kind
    /// AgentSession; the SSE stream will already have observed the
    /// `session.created` event but the registry needs both ids
    /// known before subsequent prompts can route correctly.
    ///
    /// PR #32: the `repo` parameter is optional and gets stashed in
    /// `repoBySessionID` so subsequent `usage` events tag the
    /// UsageRecord with the right cwd for per-repo analytics
    /// bucketing. Nil repos still register the id mapping but tag
    /// usage records as "(unknown)" downstream.
    public func register(clawdmeterID: UUID, opencodeID: String, repo: String? = nil) {
        sessionMap.set(clawdmeterID: clawdmeterID, opencodeID: opencodeID)
        if let repo {
            repoBySessionID[opencodeID] = repo
            // opencode ≥1.16 scopes /event by directory; this session's
            // events only flow on a stream subscribed with its repo dir.
            ensureStreamRunning(directory: repo)
        }
    }

    // MARK: - Stream loop

    private func runStreamLoop(directory: String) async {
        while !Task.isCancelled {
            guard let request = makeStreamRequest(directory: directory) else {
                // OpencodeProcessManager isn't running. Wait + retry.
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                continue
            }
            let backoffAttempt: Int
            do {
                try await consumeStream(request: request, directory: directory)
                // consumeStream returns when the server closes the
                // connection cleanly — drop into reconnect with backoff.
                Self.liveDebug("stream closed cleanly directory=\(directory.isEmpty ? "<unscoped>" : directory)")
                resetReconnectFailuresAfterCleanClose(directory: directory)
                backoffAttempt = 1
            } catch {
                logger.warning("opencode SSE error: \(error.localizedDescription, privacy: .public)")
                Self.liveDebug("stream error directory=\(directory.isEmpty ? "<unscoped>" : directory): \(error.localizedDescription)")
                guard !recordReconnectFailureAndShouldStop(directory: directory) else { return }
                backoffAttempt = reconnectCounts[directory] ?? 1
            }
            // Backoff before reconnecting.
            let clampedAttempt = max(1, backoffAttempt)
            let backoffNs = UInt64(500_000_000) * UInt64(1 << min(clampedAttempt, 6))
            try? await Task.sleep(nanoseconds: backoffNs)
        }
    }

    private func resetReconnectFailuresAfterCleanClose(directory: String = "") {
        reconnectCounts[directory] = 0
    }

    @discardableResult
    private func recordReconnectFailureAndShouldStop(directory: String = "") -> Bool {
        let count = (reconnectCounts[directory] ?? 0) + 1
        reconnectCounts[directory] = count
        if count > Self.maxReconnects {
            logger.error("opencode SSE: exhausted \(Self.maxReconnects) reconnect attempts; stopping")
            return true
        }
        return false
    }

    internal var reconnectCountForTesting: Int {
        reconnectCounts[""] ?? 0
    }

    internal func recordCleanStreamCompletionForTesting() {
        resetReconnectFailuresAfterCleanClose()
    }

    @discardableResult
    internal func recordStreamFailureForTesting() -> Bool {
        recordReconnectFailureAndShouldStop()
    }

    internal var activeStreamDirectoriesForTesting: [String] {
        streamDirectoryOrder
    }

    private func makeStreamRequest(directory: String) -> URLRequest? {
        guard var req = OpencodeProcessManager.shared.makeAuthorizedRequest(
            path: "/event",
            directory: directory.isEmpty ? nil : directory
        ) else {
            return nil
        }
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        // SSE must not ride a buffering content-coding: a gzip/br window
        // holds events back until flush, which reads as "connected but
        // silent" on long-lived streams.
        req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let lastEventId = lastEventIds[directory] {
            req.setValue(lastEventId, forHTTPHeaderField: "Last-Event-ID")
        }
        req.timeoutInterval = 0  // SSE: never time out
        return req
    }

    /// Consume one SSE connection. `nonisolated` on purpose: iterating
    /// `URLSession.AsyncBytes.lines` from the MainActor starved the
    /// stream inside app-hosted processes (observed live 2026-06-10:
    /// HTTP 200, then zero lines ever yielded while a background-task
    /// consumer of the identical request streamed fine) — and SSE
    /// parsing is exactly the kind of continuous I/O work that should
    /// never sit on the main actor anyway. Each complete event hops to
    /// the MainActor once for dispatch/bookkeeping.
    nonisolated private func consumeStream(request: URLRequest, directory: String) async throws {
        let session = URLSession(configuration: .ephemeral)
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard http.statusCode == 200 else {
            Self.liveDebug("stream HTTP \(http.statusCode) directory=\(directory.isEmpty ? "<unscoped>" : directory)")
            throw URLError(.badServerResponse, userInfo: ["statusCode": http.statusCode])
        }
        Self.liveDebug("stream connected HTTP 200 directory=\(directory.isEmpty ? "<unscoped>" : directory) content-type=\(http.value(forHTTPHeaderField: "Content-Type") ?? "?") content-encoding=\(http.value(forHTTPHeaderField: "Content-Encoding") ?? "none")")
        // SSE frames end with a blank line, but `AsyncBytes.lines` never
        // yields empty lines — a terminator-driven parser dispatches
        // NOTHING (observed live 2026-06-10: 129 data lines consumed,
        // zero events dispatched). Instead, dispatch as soon as the
        // accumulated `data:` payload parses as complete JSON; partial
        // payloads (multi-line data frames) keep accumulating.
        var dataAccumulator = ""
        var idForCurrentEvent: String?
        for try await line in bytes.lines {
            if line.isEmpty {
                // Defensive: dispatch on a terminator if the line
                // iterator ever starts yielding blanks.
                if !dataAccumulator.isEmpty {
                    await ingestStreamPayload(
                        jsonString: dataAccumulator,
                        eventId: idForCurrentEvent,
                        directory: directory
                    )
                }
                dataAccumulator = ""
                idForCurrentEvent = nil
                continue
            }
            // RFC 8895 event-stream parse (simplified — we only care
            // about `data:` and `id:` fields; opencode doesn't emit
            // `event:` or `retry:`).
            if line.hasPrefix("data:") {
                let chunk = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                if dataAccumulator.isEmpty {
                    dataAccumulator = chunk
                } else {
                    dataAccumulator += "\n" + chunk
                }
                if Self.isCompleteJSONObject(dataAccumulator) {
                    await ingestStreamPayload(
                        jsonString: dataAccumulator,
                        eventId: idForCurrentEvent,
                        directory: directory
                    )
                    dataAccumulator = ""
                    idForCurrentEvent = nil
                }
            } else if line.hasPrefix("id:") {
                idForCurrentEvent = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            }
            // Other field lines (event:, retry:, comments) are ignored.
        }
    }

    /// True when the accumulated `data:` payload is one complete JSON
    /// object — the dispatch trigger that replaces the blank-line frame
    /// terminator `AsyncBytes.lines` swallows.
    nonisolated internal static func isCompleteJSONObject(_ payload: String) -> Bool {
        guard payload.hasPrefix("{"), payload.hasSuffix("}"),
              let data = payload.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) is [String: Any]
    }

    /// MainActor landing point for one complete SSE event.
    private func ingestStreamPayload(jsonString: String, eventId: String?, directory: String) {
        dispatchEvent(jsonString: jsonString)
        reconnectCounts[directory] = 0  // success: reset backoff
        if let eventId {
            lastEventIds[directory] = eventId
        }
    }

    // MARK: - Event dispatch (testable surface)

    /// Decode an SSE `data:` payload and route to the appropriate
    /// internal handler. Internal so tests can call directly without
    /// spinning up the full network stack.
    internal func dispatchEvent(jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            logger.warning("opencode SSE: dropped malformed event payload")
            return
        }
        // Overlapping directory streams can deliver the same event twice;
        // replaying a completion would double-count its token deltas.
        if let eventId = envelope["id"] as? String, !eventId.isEmpty {
            if recentEventIdSet.contains(eventId) { return }
            recentEventIdSet.insert(eventId)
            recentEventIds.append(eventId)
            if recentEventIds.count > Self.maxRecentEventIds {
                recentEventIdSet.remove(recentEventIds.removeFirst())
            }
        }
        let type = envelope["type"] as? String ?? ""
        let properties = envelope["properties"] as? [String: Any] ?? [:]
        Self.liveDebug("event type=\(type)")
        handleEvent(type: type, properties: properties)
    }

    /// Per-event-type dispatch. Internal so tests can verify each
    /// branch in isolation.
    internal func handleEvent(type: String, properties: [String: Any]) {
        switch type {
        case "session.created":
            handleSessionCreated(properties: properties)
        case "message.added":
            handleMessageAdded(properties: properties)
        case "usage":
            handleUsage(properties: properties)
        case "session.error":
            handleSessionError(properties: properties)
        // opencode ≥1.16 turn vocabulary (message.added is retired there).
        case "message.updated":
            handleMessageUpdated(properties: properties)
        case "message.part.updated":
            handleMessagePartUpdated(properties: properties)
        case "message.part.delta":
            handleMessagePartDelta(properties: properties)
        case "session.status":
            handleSessionStatus(properties: properties)
        case "session.idle":
            handleSessionIdle(properties: properties)
        case "":
            // Empty type — opencode occasionally emits keep-alive frames.
            return
        default:
            logger.debug("opencode SSE: unhandled event type \(type, privacy: .public)")
        }
    }

    // MARK: - opencode ≥1.16 turn projection

    /// `message.updated` carries the message's role and, for assistant
    /// messages, the completion marker (`info.time.completed` /
    /// `info.finish`) plus token totals and model id. Role arrives
    /// before the message's parts in practice; recording it here is
    /// what lets the part handlers decide assistant-vs-user projection.
    private func handleMessageUpdated(properties: [String: Any]) {
        guard let info = properties["info"] as? [String: Any],
              let messageID = info["id"] as? String else { return }
        let opencodeID = (properties["sessionID"] as? String)
            ?? (info["sessionID"] as? String)
        if let role = info["role"] as? String {
            messageRoleByID[messageID] = role
        }
        if let opencodeID {
            messageOpencodeSessionByID[messageID] = opencodeID
        }
        guard messageRoleByID[messageID] == "assistant",
              let opencodeID,
              let clawdmeterID = sessionMap.opencodeToClawdmeter[opencodeID] else { return }

        let time = info["time"] as? [String: Any]
        let isCompleted = time?["completed"] != nil || info["finish"] != nil
        guard let store = chatStoreAccessor?(clawdmeterID) else { return }

        if isCompleted {
            // Final projection: re-upsert the joined text (covers a
            // completion racing ahead of the last part snapshot) and
            // attach the turn's token totals + model in the same append
            // so cost/usage land with the finished message.
            let body = joinedAssistantText(messageID: messageID)
            let tokens = info["tokens"] as? [String: Any]
            let cache = tokens?["cache"] as? [String: Any]
            let input = (tokens?["input"] as? Int) ?? 0
            // opencode reports reasoning tokens separately; they bill as
            // output-side generation, so fold them into the output delta.
            let output = ((tokens?["output"] as? Int) ?? 0) + ((tokens?["reasoning"] as? Int) ?? 0)
            let cacheWrite = (cache?["write"] as? Int) ?? 0
            let cacheRead = (cache?["read"] as? Int) ?? 0
            let model = info["modelID"] as? String
            var messages: [ChatMessage] = []
            if !body.isEmpty {
                messages = [ChatMessage(
                    id: messageID,
                    kind: .assistantText,
                    title: "Assistant",
                    body: body,
                    at: Date()
                )]
            }
            store.appendSDKMessages(
                messages,
                deltaInputTokens: input,
                deltaOutputTokens: output,
                deltaCacheCreationTokens: cacheWrite,
                deltaCacheReadTokens: cacheRead,
                model: model
            )
            store.setCurrentTurnState(.completed)
            cleanupBuffers(forMessageID: messageID)
            AgentEventStream.recordEvent(
                sessionId: clawdmeterID,
                kind: .snapshot,
                payload: ["opencodeSessionID": opencodeID]
            )
        } else {
            store.setCurrentTurnState(.streaming)
        }
    }

    /// `message.part.updated` carries a cumulative snapshot of one part.
    /// SET semantics on the part buffer keep this idempotent against the
    /// interleaved `message.part.delta` appends regardless of arrival order.
    private func handleMessagePartUpdated(properties: [String: Any]) {
        guard let part = properties["part"] as? [String: Any],
              let partID = part["id"] as? String,
              let messageID = part["messageID"] as? String else { return }
        enforceBufferCap()
        let kind = (part["type"] as? String) ?? ""
        partKindByID[partID] = kind
        if let opencodeID = (properties["sessionID"] as? String) ?? (part["sessionID"] as? String) {
            messageOpencodeSessionByID[messageID] = opencodeID
        }
        if var order = partOrderByMessageID[messageID] {
            if !order.contains(partID) {
                order.append(partID)
                partOrderByMessageID[messageID] = order
            }
        } else {
            partOrderByMessageID[messageID] = [partID]
        }
        if kind == "text", let text = part["text"] as? String {
            partTextByID[partID] = text
        }
        markAssistantStreaming(messageID: messageID)
    }

    /// `message.part.delta` appends incremental text to a part buffer.
    /// Deltas stream for reasoning parts too, so projection still gates
    /// on the part's recorded kind; a delta that precedes its part's
    /// first `message.part.updated` buffers under an unknown kind and
    /// projects once the kind is known.
    private func handleMessagePartDelta(properties: [String: Any]) {
        guard let partID = properties["partID"] as? String,
              let messageID = properties["messageID"] as? String,
              (properties["field"] as? String) == "text",
              let delta = properties["delta"] as? String else { return }
        enforceBufferCap()
        if let opencodeID = properties["sessionID"] as? String {
            messageOpencodeSessionByID[messageID] = opencodeID
        }
        if var order = partOrderByMessageID[messageID] {
            if !order.contains(partID) {
                order.append(partID)
                partOrderByMessageID[messageID] = order
            }
        } else {
            partOrderByMessageID[messageID] = [partID]
        }
        partTextByID[partID] = (partTextByID[partID] ?? "") + delta
        markAssistantStreaming(messageID: messageID)
    }

    /// `session.status` mirrors busy/idle turn activity; `session.idle`
    /// is the terminal marker. Idle only upgrades a streaming turn to
    /// completed — it must not overwrite an interrupted/error state.
    private func handleSessionStatus(properties: [String: Any]) {
        guard let opencodeID = properties["sessionID"] as? String,
              let clawdmeterID = sessionMap.opencodeToClawdmeter[opencodeID],
              let status = properties["status"] as? [String: Any],
              let statusType = status["type"] as? String else { return }
        switch statusType {
        case "busy":
            chatStoreAccessor?(clawdmeterID)?.setCurrentTurnState(.streaming)
        case "idle":
            completeStreamingTurn(opencodeID: opencodeID, clawdmeterID: clawdmeterID)
        default:
            break
        }
    }

    private func handleSessionIdle(properties: [String: Any]) {
        guard let opencodeID = properties["sessionID"] as? String,
              let clawdmeterID = sessionMap.opencodeToClawdmeter[opencodeID] else { return }
        completeStreamingTurn(opencodeID: opencodeID, clawdmeterID: clawdmeterID)
    }

    private func completeStreamingTurn(opencodeID: String, clawdmeterID: UUID) {
        if let store = chatStoreAccessor?(clawdmeterID),
           store.snapshot.currentTurnState == .streaming {
            store.setCurrentTurnState(.completed)
        }
        // Idle is per-session terminal: drop buffered part state for every
        // message we tracked against this opencode session.
        let messageIDs = messageOpencodeSessionByID.filter { $0.value == opencodeID }.map(\.key)
        for messageID in messageIDs {
            cleanupBuffers(forMessageID: messageID)
        }
        AgentEventStream.recordEvent(
            sessionId: clawdmeterID,
            kind: .snapshot,
            payload: ["opencodeSessionID": opencodeID]
        )
    }

    /// Keep the turn in streaming state while an assistant message's
    /// parts/deltas flow. The body itself projects exactly once, at the
    /// `message.updated` completion marker — the chat store's staging
    /// pipeline is first-wins by message id (no in-place body growth),
    /// so partial appends would freeze the row at its first fragment.
    private func markAssistantStreaming(messageID: String) {
        guard messageRoleByID[messageID] == "assistant",
              let opencodeID = messageOpencodeSessionByID[messageID],
              let clawdmeterID = sessionMap.opencodeToClawdmeter[opencodeID],
              let store = chatStoreAccessor?(clawdmeterID) else { return }
        store.setCurrentTurnState(.streaming)
    }

    private func joinedAssistantText(messageID: String) -> String {
        let order = partOrderByMessageID[messageID] ?? []
        return order
            .filter { partKindByID[$0] == "text" }
            .compactMap { partTextByID[$0] }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private func cleanupBuffers(forMessageID messageID: String) {
        for partID in partOrderByMessageID[messageID] ?? [] {
            partTextByID.removeValue(forKey: partID)
            partKindByID.removeValue(forKey: partID)
        }
        partOrderByMessageID.removeValue(forKey: messageID)
        messageRoleByID.removeValue(forKey: messageID)
        messageOpencodeSessionByID.removeValue(forKey: messageID)
    }

    private func enforceBufferCap() {
        guard partTextByID.count > Self.maxBufferedParts else { return }
        logger.warning("opencode SSE: part buffer cap exceeded; dropping buffered turn state")
        messageRoleByID.removeAll()
        messageOpencodeSessionByID.removeAll()
        partKindByID.removeAll()
        partTextByID.removeAll()
        partOrderByMessageID.removeAll()
    }

    private func handleSessionCreated(properties: [String: Any]) {
        guard let opencodeID = properties["id"] as? String else { return }
        // The Clawdmeter side already created a UUID when AgentControlServer
        // routed POST /sessions through us; that mapping is registered via
        // `register(clawdmeterID:opencodeID:)`. If we receive a
        // session.created without a prior registration, it means the user
        // started the session out-of-band (e.g. via `opencode` CLI directly);
        // we synthesize a Clawdmeter session for it so it surfaces in the
        // sessions list. The synthesis hook lands when AgentControlServer's
        // registry exposes a create-from-opencode entry point (queued).
        if sessionMap.opencodeToClawdmeter[opencodeID] == nil {
            logger.info("opencode SSE: session.created for unknown opencodeID \(opencodeID, privacy: .public) — synthesis hook not plumbed yet")
        }
    }

    private func handleMessageAdded(properties: [String: Any]) {
        guard let opencodeID = properties["sessionID"] as? String,
              let clawdmeterID = sessionMap.opencodeToClawdmeter[opencodeID] else {
            logger.debug("opencode message.added for unknown sessionID")
            return
        }
        // v0.23.2: route the opencode `message.added` payload into
        // the session's SessionChatStore so chat-subscribe WS clients
        // (iOS chat thread, Mac live workspace) see the assistant turn
        // immediately. Falls back to a snapshot AgentEventStream signal
        // when the chat-store accessor isn't wired (test paths /
        // pre-injection).
        if let chatMessage = Self.parseMessageAdded(properties: properties) {
            if let store = chatStoreAccessor?(clawdmeterID) {
                store.appendSDKMessages([chatMessage])
                Self.updateTurnState(for: chatMessage, store: store)
                logger.debug("opencode message.added: appended \(chatMessage.kind.rawValue, privacy: .public) id=\(chatMessage.id, privacy: .public)")
            } else {
                logger.debug("opencode message.added: no chat-store accessor wired — emitting snapshot only")
            }
        }
        // Always emit the snapshot signal too so downstream consumers
        // (per-session refresh nudges, badge counters) update even when
        // we couldn't extract a parseable ChatMessage from the payload.
        AgentEventStream.recordEvent(
            sessionId: clawdmeterID,
            kind: .snapshot,
            payload: ["opencodeSessionID": opencodeID]
        )
    }

    private static func updateTurnState(for message: ChatMessage, store: SessionChatStore) {
        if message.isError {
            store.setCurrentTurnState(.interrupted)
            return
        }
        switch message.kind {
        case .assistantText:
            store.setCurrentTurnState(.completed)
        case .userText, .toolCall, .toolResult, .meta:
            store.setCurrentTurnState(.streaming)
        }
    }

    /// Convert an opencode `message.added` event into a `ChatMessage`
    /// the SessionChatStore staging pipeline accepts. opencode's wire
    /// shape varies across minor versions; we accept several known
    /// patterns and fall through to nil for anything unrecognized.
    ///
    /// Known shapes (captured 2026-05-23 against opencode v1.15.x):
    ///
    ///   properties.message = {
    ///     id: "msg_...",
    ///     role: "assistant" | "user",
    ///     content: [
    ///       {type: "text", text: "..."},
    ///       {type: "tool-call", name: "Bash", input: {...}}
    ///     ]
    ///   }
    ///
    /// For tool-call entries we emit a `.toolCall` ChatMessage with
    /// `title=<tool-name>` and `body=<JSON-stringified-input>`. Text
    /// entries produce a single `.userText` / `.assistantText` row
    /// concatenating any sibling text deltas. Mixed-content messages
    /// (text + tool calls) emit multiple ChatMessages sharing the
    /// same `at` timestamp; the staging pipeline orders them by the
    /// implicit "tool_use before tool_result" rule.
    ///
    /// Returns nil when properties.message is missing or unparseable —
    /// the caller still emits the snapshot signal so the UI can probe
    /// the opencode HTTP API for the full state. Internal so tests
    /// can drive each known wire shape directly.
    ///
    /// F1c-wire shipped in #164 and is now default-ON per F1-finalize:
    /// every `message.added` SSE event routes through
    /// `parseMessageAddedViaAdapter` so the canonical
    /// `ProviderRuntimeEvent` pipeline owns the role + content extraction.
    /// The `FeatureFlags.useOpenCodeAdapter` env/UserDefaults override
    /// remains live as a rollback escape hatch — flip the env to
    /// `CLAWDMETER_USE_OPENCODE_ADAPTER=0` and `parseMessageAddedLegacy`
    /// lights back up unchanged. Parity enforced by
    /// `F1cWireChatParityTests`.
    internal static func parseMessageAdded(properties: [String: Any]) -> ChatMessage? {
        if FeatureFlags.useOpenCodeAdapter {
            return parseMessageAddedViaAdapter(properties: properties)
        }
        return parseMessageAddedLegacy(properties: properties)
    }

    /// Legacy parser — the pre-F1c-wire implementation. Untouched logic so
    /// the flag-off path stays bit-for-bit identical to the historical
    /// behavior covered by `OpencodeSSEAdapterTests`.
    internal static func parseMessageAddedLegacy(properties: [String: Any]) -> ChatMessage? {
        guard let msg = properties["message"] as? [String: Any] else { return nil }
        let role = (msg["role"] as? String) ?? "assistant"
        let kind: ChatMessage.Kind = (role == "user") ? .userText : .assistantText
        let messageId = (msg["id"] as? String) ?? UUID().uuidString
        let now = Date()
        // content may be a string OR an array of typed parts.
        if let plain = msg["content"] as? String {
            return ChatMessage(
                id: messageId,
                kind: kind,
                title: role.capitalized,
                body: plain,
                at: now
            )
        }
        if let parts = msg["content"] as? [[String: Any]] {
            // Concatenate text fragments; keep the first tool-call/result
            // as a fallback. The v0.23.2 pass emits one ChatMessage per
            // message.added event — future PR can decompose mixed-content
            // into multiple rows if a real opencode session demonstrates
            // text + tool fan-out in the same delta (uncommon today).
            var textBuffer: [String] = []
            for part in parts {
                if let type = part["type"] as? String {
                    switch type {
                    case "text":
                        if let t = part["text"] as? String { textBuffer.append(t) }
                    case "tool-call", "tool_use":
                        let name = (part["name"] as? String) ?? "tool"
                        let inputDesc: String = {
                            if let input = part["input"] {
                                if let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]),
                                   let s = String(data: data, encoding: .utf8) {
                                    return s
                                }
                                return String(describing: input)
                            }
                            return ""
                        }()
                        return ChatMessage(
                            id: messageId,
                            kind: .toolCall,
                            title: name,
                            body: inputDesc,
                            at: now
                        )
                    case "tool-result", "tool_result":
                        let body = (part["output"] as? String)
                            ?? (part["text"] as? String)
                            ?? ""
                        let isError = (part["isError"] as? Bool) ?? false
                        return ChatMessage(
                            id: messageId,
                            kind: .toolResult,
                            title: "Result",
                            body: body,
                            at: now,
                            isError: isError
                        )
                    default:
                        break
                    }
                }
            }
            let joined = textBuffer.joined(separator: "\n")
            guard !joined.isEmpty else { return nil }
            return ChatMessage(
                id: messageId,
                kind: kind,
                title: role.capitalized,
                body: joined,
                at: now
            )
        }
        return nil
    }

    /// F1c-wire adapter-routed decoder. Mirrors the F1a-wire pattern:
    /// runs `OpenCodeAdapter.translate(...)` to confirm the canonical
    /// `ProviderRuntimeEvent` pipeline lights up under load, then
    /// delegates to the legacy parser verbatim for `ChatMessage`
    /// construction so per-block UI fields (tool-call / tool-result
    /// shapes) stay bit-for-bit identical.
    ///
    /// Why delegate to legacy for ChatMessage construction? The
    /// adapter's canonical events carry the *role* + *text* + *tokens*
    /// projection, but the chat UI needs the tool-call short-circuit
    /// + tool-result kind/isError mapping that's encoded in the
    /// legacy parser. Migrating those into the canonical
    /// `ExtensionField` envelope is a future PR — this wire just
    /// proves the adapter path is exercised in CI.
    ///
    /// Drops the line (returns nil) for the same shapes legacy drops:
    /// missing `properties.message`, content-array with no text + no
    /// recognized tool parts.
    internal static func parseMessageAddedViaAdapter(properties: [String: Any]) -> ChatMessage? {
        // Adapter contract: `OpenCodeAdapter.translate` needs a
        // `messageId` (used as the canonical event id + dedupe key).
        // The legacy parser synthesizes one when absent; do the same
        // here so the adapter has a stable id to attach events to.
        guard let msg = properties["message"] as? [String: Any] else { return nil }
        let messageId = (msg["id"] as? String) ?? UUID().uuidString
        let now = Date()

        // Run the adapter on the same raw input. We don't consume the
        // events here for ChatMessage construction — legacy owns that
        // — but exercising the translation step makes sure the
        // canonical path is wired and surfaces any divergence early.
        // sessionId is a Clawdmeter concept; pass an empty string
        // (matches the analytics bridge convention).
        let events = OpenCodeAdapter.translate(
            message: msg,
            messageId: messageId,
            timestamp: now,
            sessionId: "",
            sequenceStart: 0,
            providerInstanceId: nil,
            rawBytes: nil
        )

        // The adapter emits at least one event for any message dict
        // with role assistant/user/unknown. If it emitted nothing,
        // the input was so malformed that legacy would also drop it.
        guard !events.isEmpty else { return nil }

        // Delegate to legacy for ChatMessage construction. Per the
        // strangler-fig contract this MUST be identical to the
        // flag-off path bit-for-bit.
        return parseMessageAddedLegacy(properties: properties)
    }

    /// Handle an opencode `usage` event by mapping it to a UsageRecord
    /// through OpencodeUsageMapper and broadcasting via NotificationCenter.
    /// UsageHistoryStore subscribes to the notification and folds the
    /// record into its rolling in-memory bag for the menu-bar dollar
    /// gauge + Analytics. PR #31 chunk 3.
    ///
    /// Notification-based wire (instead of a direct UsageHistoryStore
    /// singleton) keeps the SSE adapter loosely coupled — the store is
    /// owned by AppRuntime and not globally addressable.
    private func handleUsage(properties: [String: Any]) {
        // PR #32: the opencode `usage` SSE event carries `sessionID`
        // (the opencode-side id), which we map back to the repo we
        // stashed at register() time. Falls back to nil when the
        // mapping is missing — out-of-band sessions started via
        // `opencode` CLI directly won't have a Clawdmeter-side repo
        // record. Analytics buckets nil under "(unknown)".
        let repo: String? = {
            guard let opencodeID = properties["sessionID"] as? String else { return nil }
            return repoBySessionID[opencodeID]
        }()
        guard let record = OpencodeUsageMapper.mapEvent(
            properties: properties,
            repo: repo
        ) else {
            logger.debug("opencode usage: dropped malformed event payload")
            return
        }
        NotificationCenter.default.post(
            name: .opencodeUsageRecorded,
            object: nil,
            userInfo: ["record": record]
        )
        logger.debug("opencode usage: ingested model=\(record.model, privacy: .public) total=\(record.tokens.totalTokens, privacy: .public) cost=\(String(describing: record.tokens.costUSD), privacy: .public)")
    }

    private func handleSessionError(properties: [String: Any]) {
        guard let opencodeID = properties["sessionID"] as? String,
              let clawdmeterID = sessionMap.opencodeToClawdmeter[opencodeID] else { return }
        let detail = (properties["error"] as? String) ?? "unknown error"
        if let store = chatStoreAccessor?(clawdmeterID) {
            store.appendSDKMessages([
                ChatMessage(
                    id: "opencode-error-\(Date().timeIntervalSince1970)-\(UUID().uuidString.prefix(8))",
                    kind: .assistantText,
                    title: "OpenCode",
                    body: detail,
                    at: Date(),
                    isError: true
                )
            ])
            store.setCurrentTurnState(.interrupted)
        }
        AgentEventStream.recordEvent(
            sessionId: clawdmeterID,
            kind: .statusChanged,
            payload: ["status": "degraded", "detail": detail]
        )
    }

    // MARK: - Bidirectional map

    /// Two-way map between Clawdmeter session UUIDs and opencode session
    /// id strings. Kept here (not in the registry) because it's
    /// adapter-private state — the registry only ever sees Clawdmeter
    /// UUIDs.
    public struct BidirectionalMap: Sendable {
        public private(set) var clawdmeterToOpencode: [UUID: String] = [:]
        public private(set) var opencodeToClawdmeter: [String: UUID] = [:]

        public mutating func set(clawdmeterID: UUID, opencodeID: String) {
            clawdmeterToOpencode[clawdmeterID] = opencodeID
            opencodeToClawdmeter[opencodeID] = clawdmeterID
        }

        public mutating func removeAll() {
            clawdmeterToOpencode.removeAll()
            opencodeToClawdmeter.removeAll()
        }
    }
}

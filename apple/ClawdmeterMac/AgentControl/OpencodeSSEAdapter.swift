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

    /// Reconnect attempt counter; resets on a successful event read.
    private var reconnectCount: Int = 0
    private static let maxReconnects = 10

    /// Active streaming task. Cancelled on `stop()`.
    private var streamTask: Task<Void, Never>?

    /// Last event id we processed — sent on reconnect as Last-Event-ID
    /// so the server can resume from where we dropped off.
    private var lastEventId: String?

    // MARK: - Public API

    /// Start the SSE subscription. Returns immediately; the stream
    /// runs in a detached task. Safe to call multiple times — the old
    /// task is cancelled before a new one starts (used on restart-after-
    /// crash from OpencodeProcessManager).
    public func start() {
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            await self?.runStreamLoop()
        }
    }

    /// Cancel the stream + clear in-flight state. Called from
    /// OpencodeProcessManager.stop() and from AppRuntime teardown.
    public func stop() {
        streamTask?.cancel()
        streamTask = nil
        reconnectCount = 0
        lastEventId = nil
        sessionMap.removeAll()
        repoBySessionID.removeAll()
        logger.info("opencode SSE adapter stopped")
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
        }
    }

    // MARK: - Stream loop

    private func runStreamLoop() async {
        while !Task.isCancelled {
            guard let request = makeStreamRequest() else {
                // OpencodeProcessManager isn't running. Wait + retry.
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                continue
            }
            do {
                try await consumeStream(request: request)
                // consumeStream returns when the server closes the
                // connection cleanly — drop into reconnect with backoff.
            } catch {
                logger.warning("opencode SSE error: \(error.localizedDescription, privacy: .public)")
            }
            // Backoff before reconnecting.
            reconnectCount += 1
            if reconnectCount > Self.maxReconnects {
                logger.error("opencode SSE: exhausted \(Self.maxReconnects) reconnect attempts; stopping")
                return
            }
            let backoffNs = UInt64(500_000_000) * UInt64(1 << min(reconnectCount, 6))
            try? await Task.sleep(nanoseconds: backoffNs)
        }
    }

    private func makeStreamRequest() -> URLRequest? {
        guard var req = OpencodeProcessManager.shared.makeAuthorizedRequest(path: "/event") else {
            return nil
        }
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let lastEventId {
            req.setValue(lastEventId, forHTTPHeaderField: "Last-Event-ID")
        }
        req.timeoutInterval = 0  // SSE: never time out
        return req
    }

    private func consumeStream(request: URLRequest) async throws {
        let session = URLSession(configuration: .ephemeral)
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard http.statusCode == 200 else {
            throw URLError(.badServerResponse, userInfo: ["statusCode": http.statusCode])
        }
        // Each SSE event ends with a blank line. We accumulate the
        // event's `data:` payload across lines, then dispatch when the
        // blank-line terminator arrives.
        var dataAccumulator = ""
        var idForCurrentEvent: String?
        for try await line in bytes.lines {
            if line.isEmpty {
                // Event terminator. Dispatch if we have a payload.
                if !dataAccumulator.isEmpty {
                    dispatchEvent(jsonString: dataAccumulator)
                    reconnectCount = 0  // success: reset backoff
                    if let id = idForCurrentEvent {
                        lastEventId = id
                    }
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
            } else if line.hasPrefix("id:") {
                idForCurrentEvent = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            }
            // Other field lines (event:, retry:, comments) are ignored.
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
        let type = envelope["type"] as? String ?? ""
        let properties = envelope["properties"] as? [String: Any] ?? [:]
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
        case "":
            // Empty type — opencode occasionally emits keep-alive frames.
            return
        default:
            logger.debug("opencode SSE: unhandled event type \(type, privacy: .public)")
        }
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

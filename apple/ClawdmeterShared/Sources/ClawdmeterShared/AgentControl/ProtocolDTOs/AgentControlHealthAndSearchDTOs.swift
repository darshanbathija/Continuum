import Foundation

// MARK: - History search (Chat V2, wire v14)

/// One match in a `GET /chat-sessions/search?q=<query>` response.
/// Daemon walks the JSONL files indexed by `SessionFileResolver` and
/// returns matches ranked by `lastEventAt` descending. The V2 sidebar
/// renders these inline alongside the in-memory conversation list so
/// search hits older chats too (the LRU cache only holds the 2-20
/// most recent — see Codex outside-voice review P1 #8).
public struct ChatSessionSearchMatch: Codable, Sendable, Hashable, Identifiable {
    /// The matching session's id. Same value as `AgentSession.id` when
    /// the session is still in the registry. For evicted-but-on-disk
    /// matches, the id is parsed from the JSONL filename — clients use
    /// it as the row's stable identifier but should resolve through
    /// the registry first for live state.
    public let sessionId: UUID
    /// Frontier group when the match belongs to a broadcast child.
    /// Lets clients open the aggregate comparison even when the child
    /// session has not been loaded into the local cache yet.
    public let frontierGroupId: UUID?
    /// Absolute path to the JSONL on disk. Lets the client open the
    /// transcript via the existing `/transcript?path=` endpoint when
    /// the session isn't in the registry.
    public let jsonlPath: String
    /// ≤120-character excerpt of the matched line(s) — body text with
    /// the match centered + an ellipsis on either side when truncated.
    /// Multi-line matches are joined with a space.
    public let snippet: String
    /// File mtime of the JSONL. Drives rank order in the result list
    /// (newest first) AND the relative-time label in the V2 sidebar
    /// search results row ("2h ago", "3d ago").
    public let lastEventAt: Date

    public var id: UUID { sessionId }

    public init(
        sessionId: UUID,
        frontierGroupId: UUID? = nil,
        jsonlPath: String,
        snippet: String,
        lastEventAt: Date
    ) {
        self.sessionId = sessionId
        self.frontierGroupId = frontierGroupId
        self.jsonlPath = jsonlPath
        self.snippet = snippet
        self.lastEventAt = lastEventAt
    }
}

/// Envelope for `GET /chat-sessions/search`. Wraps the match array so
/// future fields (paging cursor, total count, query-timing) can land
/// additively without a wire bump.
public struct ChatSessionSearchResponse: Codable, Sendable {
    public let matches: [ChatSessionSearchMatch]
    /// True when the search was truncated by the daemon's hard timeout
    /// (200ms) or the result cap (50). Clients render "+ more —
    /// narrow your query" below the list when set.
    public let truncated: Bool

    public init(matches: [ChatSessionSearchMatch], truncated: Bool = false) {
        self.matches = matches
        self.truncated = truncated
    }
}

// MARK: - Per-turn lifecycle (Chat V2, wire v14)

/// Explicit lifecycle state for the most-recent turn on a chat session.
/// Emitted by the daemon's per-provider ingestors when they see each
/// provider's natural end-of-turn marker. The Chat V2 status strip
/// drives its stopwatch + Stop↔Send transition off this field; without
/// it the UI has to guess via a 2-second heartbeat heuristic that
/// flickers on slow tool calls. `.idle` is the decode-default so older
/// Macs (wire v13) round-trip through V2 clients without crashing.
///
/// Transition contract:
///   - `.idle` → `.streaming` when the user sends a prompt and the
///     first assistant token (or first tool_use) lands in the JSONL /
///     sidecar event stream.
///   - `.streaming` → `.completed` on the provider's natural turn end
///     (Claude: `result` line in JSONL; Codex SDK: `turn.completed`
///     event; Antigravity: `chunk_done` / agentapi terminal frame).
///   - `.streaming` → `.interrupted` when SessionInterruptDispatcher
///     dispatches the cancel for that session (tmux ESC / SDK
///     AbortController.abort() / agentapi /cancel POST).
///   - Any state → `.idle` when the next user prompt arrives (clears
///     the previous turn's state so the stopwatch resets).
public enum TurnState: String, Codable, Hashable, Sendable, CaseIterable {
    case idle
    case streaming
    case completed
    case interrupted

    /// Lenient decoder so a future-wire-version daemon that adds a
    /// new state doesn't crash older clients. Unknown raws fall back
    /// to `.streaming` (the safest default — UI keeps showing the
    /// indicator instead of pretending the turn is done).
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        self = TurnState(rawValue: raw) ?? .streaming
    }
}

/// `GET /health` response. Old clients tolerate the extra fields; new
/// clients consume `wireVersion` and `serverVersion`.
public struct HealthResponse: Codable, Sendable {
    public let ok: Bool
    public let serverVersion: String
    public let wireVersion: Int

    public init(ok: Bool = true, serverVersion: String, wireVersion: Int = AgentControlWireVersion.current) {
        self.ok = ok
        self.serverVersion = serverVersion
        self.wireVersion = wireVersion
    }
}

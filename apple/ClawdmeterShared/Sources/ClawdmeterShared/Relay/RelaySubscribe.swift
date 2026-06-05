import Foundation

/// Track B — B0: subscribe-spec + the server-side allowlist for the
/// loopback-WS bridge.
///
/// When iOS opens a stream over the relay it sends a `.subscribe` mux frame
/// whose payload is a `RelaySubscribeSpec` — the MINIMAL data the daemon needs
/// (which stream + which session/pane/group). The daemon NEVER trusts an
/// iOS-supplied token/op/path: it validates `op` against `RelaySubAllowlist`
/// and rebuilds the loopback WS envelope server-side with its OWN per-launch
/// loopback token (CB-P1e). That keeps a relay-peer compromise from reaching
/// arbitrary daemon WS ops or forging the loopback bearer.
public struct RelaySubscribeSpec: Codable, Equatable, Sendable {
    /// The daemon WS op — must be in `RelaySubAllowlist.ops`.
    public let op: String
    public let sessionId: String?
    public let paneId: String?
    public let since: UInt64?
    public let groupId: String?
    public let clientWireVersion: Int?

    public init(
        op: String,
        sessionId: String? = nil,
        paneId: String? = nil,
        since: UInt64? = nil,
        groupId: String? = nil,
        clientWireVersion: Int? = nil
    ) {
        self.op = op
        self.sessionId = sessionId
        self.paneId = paneId
        self.since = since
        self.groupId = groupId
        self.clientWireVersion = clientWireVersion
    }

    public func encoded() throws -> Data { try JSONEncoder().encode(self) }
    public static func decode(_ bytes: Data) -> RelaySubscribeSpec? {
        try? JSONDecoder().decode(RelaySubscribeSpec.self, from: bytes)
    }
}

/// Per-channel coalescing policy for relay subFrames (D5, corrected by CB-P1d).
/// A blanket last-write-wins would eat terminal keystrokes/output and drop
/// ordered events — only replaceable snapshot streams are coalesceable.
public enum RelaySubPolicy: Sendable, Equatable {
    /// Replaceable full-snapshot streams: a newer frame supersedes an older
    /// un-sent one. Safe to debounce (300–500ms) over the metered relay.
    case snapshotLWW
    /// Ordered byte/event streams: every frame delivered, in order, no drop.
    case orderedNoDrop
}

/// The server-side gate for relay subscriptions: which ops are reachable over
/// the relay, their coalescing policy, and the server-built loopback envelope.
public enum RelaySubAllowlist {

    /// The ONLY daemon WS ops a relay peer may open. Mirrors
    /// `AgentControlServer.routeWSSubscription`'s long-lived streams; note
    /// `compose-draft` is intentionally excluded (it's a one-shot post, routed
    /// as a normal request, not a stream).
    public static let ops: Set<String> = [
        "chat-subscribe",
        "terminal",
        "events",
        "frontier-subscribe",
        "lifecycle-subscribe",
    ]

    public static func isAllowed(_ op: String) -> Bool { ops.contains(op) }

    /// Coalescing policy per op. Snapshot streams (chat / frontier) are
    /// replaceable → LWW; terminal bytes, the event log, and the lifecycle
    /// spine are ordered → never coalesced.
    public static func policy(for op: String) -> RelaySubPolicy {
        switch op {
        case "chat-subscribe", "frontier-subscribe": return .snapshotLWW
        default: return .orderedNoDrop
        }
    }

    /// Build the loopback WS subscribe envelope SERVER-SIDE: copy only the
    /// allowlisted data fields from the (untrusted) spec and inject the
    /// daemon's OWN loopback token. Returns nil if the op isn't allowlisted.
    /// Output shape matches `AgentControlServer.WSSubscription`'s JSON.
    public static func loopbackEnvelope(spec: RelaySubscribeSpec, loopbackToken: String) -> Data? {
        guard isAllowed(spec.op) else { return nil }
        var dict: [String: Any] = ["op": spec.op, "token": loopbackToken]
        if let v = spec.sessionId { dict["sessionId"] = v }
        if let v = spec.paneId { dict["paneId"] = v }
        if let v = spec.since { dict["since"] = v }
        if let v = spec.groupId { dict["groupId"] = v }
        if let v = spec.clientWireVersion { dict["clientWireVersion"] = v }
        return try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
    }
}

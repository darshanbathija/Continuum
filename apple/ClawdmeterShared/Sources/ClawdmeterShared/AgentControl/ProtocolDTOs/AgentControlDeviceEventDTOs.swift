import Foundation

// MARK: - Pairing

/// QR-encoded pairing payload. Mac displays this; iPhone scans + parses.
///
/// Wire format: `clawdmeter://<host>:<httpPort>?token=<base64url>&ws=<wsPort>`
/// where the WebSocket port is the next free port after the HTTP one.
/// iPhone reconstructs this struct from the URL components.
public struct PairingChallenge: Codable, Sendable {
    /// MagicDNS host name (e.g. `darshans-macbook-pro.tail87a721.ts.net`).
    public let host: String
    /// HTTP port the daemon bound to (default 21731, may be 21732+ on conflict).
    public let port: Int
    /// WebSocket port for terminal + event streams. Typically `port + 1`,
    /// may differ on conflict — the daemon publishes both.
    public let wsPort: Int
    /// 32-byte high-entropy bearer token, base64url-encoded.
    public let token: String
    /// v16: when true, the pairing URL used the `clawdmeters://` scheme,
    /// indicating the Mac will eventually wrap its daemon in TLS. iOS
    /// flips its `AgentControlClient.useHTTPS` flag so a future server
    /// TLS roll-out is automatic. Today's daemon is still plain HTTP;
    /// the flag is plumbing only.
    public let useHTTPS: Bool

    public init(host: String, port: Int, wsPort: Int, token: String,
                useHTTPS: Bool = false) {
        self.host = host
        self.port = port
        self.wsPort = wsPort
        self.token = token
        self.useHTTPS = useHTTPS
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.host = try c.decode(String.self, forKey: .host)
        self.port = try c.decode(Int.self, forKey: .port)
        self.wsPort = try c.decode(Int.self, forKey: .wsPort)
        self.token = try c.decode(String.self, forKey: .token)
        // useHTTPS is v16-only; older Macs never set it and older iOS
        // builds never persisted it. decodeIfPresent + default false
        // means both pre-v16 paths keep working.
        self.useHTTPS = try c.decodeIfPresent(Bool.self, forKey: .useHTTPS) ?? false
        // v0.27.0: PairingChallenge.designPort + designToken removed
        // along with the Design tab. Older Mac builds (pre-v0.27.0) still
        // emit those fields in the QR payload; iOS decoders silently
        // ignore unknown keys, so older pairing URLs continue to work.
    }

    private enum CodingKeys: String, CodingKey {
        case host, port, wsPort, token, useHTTPS
    }
}

/// `POST /devices/register` body. Currently a no-op endpoint (D15 dropped
/// APNS) but kept on the wire so iOS can declare itself to the daemon for
/// future-proofing (federation / multi-device debug surfaces).
public struct DeviceRegistration: Codable, Sendable {
    /// iOS-side device identifier (`UIDevice.identifierForVendor`).
    public let deviceId: String
    /// Human-readable device name (`UIDevice.name`).
    public let deviceName: String
    /// Platform: "iphone", "ipad", "watch".
    public let platform: String

    public init(deviceId: String, deviceName: String, platform: String) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.platform = platform
    }
}

// MARK: - Structured events (E8 cursor contract)

/// Tag identifying the shape of a structured event payload. Wire-stable;
/// new variants append to the end so old clients ignore unknown tags.
public enum AgentEventKind: String, Codable, Hashable, Sendable {
    /// A new session was created.
    case sessionCreated
    /// Session status transitioned.
    case statusChanged
    /// `ExitPlanMode` detected in the JSONL — plan-ready.
    case planReady
    /// Done-detector fired (D4).
    case doneDetected
    /// Session was paused (user, rate limit, or idle).
    case paused
    /// Session was deleted.
    case sessionDeleted
    /// tmux server died / recovered.
    case tmuxServerLost
    case tmuxServerRecovered
    /// Snapshot frame for cursor reconnect (sent when client's `?since=<seq>`
    /// is older than the retention window).
    case snapshot
    /// Forward-compatible fallback for event tags shipped by a newer daemon.
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AgentEventKind(rawValue: raw) ?? .unknown
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// One structured event in the per-session event stream. Sent over the WS
/// `/sessions/:id/events` endpoint. Sequenced per-session.
public struct AgentEvent: Codable, Hashable, Sendable, Identifiable {
    /// Per-session monotonic. E8 reconnect contract: client tracks the
    /// highest seq it's seen and reconnects with `?since=<seq>`.
    public let eventSeq: UInt64
    /// Which session this event is about.
    public let sessionId: UUID
    /// Event variant.
    public let kind: AgentEventKind
    /// Server-time when the event was emitted.
    public let at: Date
    /// Variant-specific payload, JSON-encoded as a string.
    /// We use a string rather than `AnyCodable` to keep the protocol
    /// strict — consumers decode based on `kind`.
    public let payload: String

    public var id: String { "\(sessionId.uuidString):\(eventSeq)" }

    public init(
        eventSeq: UInt64,
        sessionId: UUID,
        kind: AgentEventKind,
        at: Date,
        payload: String
    ) {
        self.eventSeq = eventSeq
        self.sessionId = sessionId
        self.kind = kind
        self.at = at
        self.payload = payload
    }
}

/// Snapshot frame body. Sent when a reconnecting client's cursor is older
/// than the daemon's retention window. The client should discard its local
/// session state and re-render from this.
public struct AgentEventSnapshot: Codable, Sendable {
    /// All currently-tracked sessions (replaces client's local list).
    public let sessions: [AgentSession]
    /// The `eventSeq` after which incremental events resume.
    public let asOfSeq: UInt64

    public init(sessions: [AgentSession], asOfSeq: UInt64) {
        self.sessions = sessions
        self.asOfSeq = asOfSeq
    }
}

// MARK: - Notifications (D3 revised — local notifications, no APNS)

/// One pending event the iOS app should surface as a `UNUserNotificationCenter`
/// local notification on its next `BGAppRefreshTask` fire (or immediately
/// while foregrounded over the WebSocket).
public struct NotificationEvent: Codable, Hashable, Sendable, Identifiable {
    /// Monotonic ID for ack semantics. Client acks the last id it delivered;
    /// daemon drops events with id <= ack.
    public let id: UInt64
    public let sessionId: UUID
    /// Kind of notification: "plan-ready", "session-done", "paused".
    public let kind: String
    public let title: String
    public let body: String
    public let at: Date

    public init(
        id: UInt64,
        sessionId: UUID,
        kind: String,
        title: String,
        body: String,
        at: Date
    ) {
        self.id = id
        self.sessionId = sessionId
        self.kind = kind
        self.title = title
        self.body = body
        self.at = at
    }
}

/// `GET /sessions/needs-attention` response. iOS BGAppRefreshTask reads this
/// when it wakes; for each event it hasn't yet surfaced, post a local notif.
public struct NeedsAttentionResponse: Codable, Sendable {
    public let events: [NotificationEvent]
    /// Daemon's wall clock when this response was generated. iOS shows it
    /// as "Last polled X ago" per the BGAppRefresh degradation UI spec.
    public let serverTime: Date

    public init(events: [NotificationEvent], serverTime: Date) {
        self.events = events
        self.serverTime = serverTime
    }
}

/// `POST /devices/ack-notifications` body. iOS acks the highest notification
/// id it has delivered; daemon drops everything `<= ackId`.
public struct AckNotificationsRequest: Codable, Sendable {
    public let ackId: UInt64

    public init(ackId: UInt64) {
        self.ackId = ackId
    }
}

/// Body for `POST /devices/apns-token` — the iPhone reports its APNS device
/// token so the Mac daemon can target lock-screen pushes at it. Keyed by the
/// pairing `sessionId`; `bundleId` becomes the APNS topic. Field names must
/// match the daemon's `RegisterAPNSDeviceTokenBody` decoder.
public struct RegisterAPNSDeviceTokenRequest: Codable, Sendable {
    public let deviceToken: String   // 64 lowercase hex chars (32-byte token)
    public let bundleId: String      // iPhone bundle id → APNS topic
    public let sessionId: String     // pairing session id

    public init(deviceToken: String, bundleId: String, sessionId: String) {
        self.deviceToken = deviceToken
        self.bundleId = bundleId
        self.sessionId = sessionId
    }
}

// MARK: - Terminal frames (Phase 3)

/// WS frame for `/sessions/:id/terminal` — binary payload carries the
/// `%output` bytes from tmux (already octal-decoded) for the SwiftTerm view
/// to consume. Inbound (client → server) frames carry keystroke bytes that
/// the server forwards to tmux via `send-keys -l` or `paste-buffer`.
///
/// The wire envelope is sent as a single byte tag followed by the body:
/// - tag `0x01` = OUTPUT, body = raw bytes for terminal
/// - tag `0x02` = RESIZE, body = JSON `{cols, rows}`
/// - tag `0x03` = INPUT, body = raw bytes from client to send to pane
/// - tag `0x04` = TITLE, body = UTF-8 string with new pane title
public enum TerminalFrameTag: UInt8 {
    case output = 0x01
    case resize = 0x02
    case input = 0x03
    case title = 0x04
}

/// Payload of a RESIZE frame, JSON-encoded.
public struct TerminalResize: Codable, Sendable {
    public let cols: Int
    public let rows: Int

    public init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
    }
}

// MARK: - Transcript

/// Response shape for `GET /transcript?path=<jsonl>`. Lets the iOS client
/// render the actual chat for any read-only outside-Clawdmeter session
/// (Conductor / Cursor / Terminal-launched agent) AND the live transcript
/// for a Clawdmeter-spawned session. The chat content is the same
/// `ChatMessage` shape the Mac uses in `SessionChatStore.snapshot.items`
/// after flattening tool runs — keeping the wire shape simple and the
/// iOS renderer minimal.
public struct TranscriptEnvelope: Codable, Sendable {
    /// Absolute path of the JSONL on the Mac (echoed back for sanity).
    public let path: String
    /// Chronologically sorted messages (oldest first). Capped at the
    /// limit the client requested; `truncated == true` means earlier
    /// messages exist on disk but weren't shipped.
    public let messages: [ChatMessage]
    public let truncated: Bool

    public init(path: String, messages: [ChatMessage], truncated: Bool) {
        self.path = path
        self.messages = messages
        self.truncated = truncated
    }
}

import Foundation

// AgentControl protocol DTOs (cross-platform).
//
// Wire shape between the Mac daemon (AgentControlServer) and the Mac/iOS
// SwiftUI clients. Every payload is Codable; the server serializes as JSON
// over HTTP and binary WebSocket frames where appropriate.
//
// Per E8: every structured event carries a monotonic `eventSeq` so a
// reconnecting client can request `?since=<seq>` and replay missed events.
// Per E2: these DTOs are Sendable so they cross actor / NIO event loop
// boundaries without copies tripping the type checker.

// MARK: - Repo + Session

/// Stable identifier for a repo, mirrors `RepoKey` from the existing
/// Analytics layer. Use `RepoIdentity.normalize(_:)` to convert raw cwds.
public struct AgentRepo: Codable, Hashable, Sendable {
    /// Canonical repo path (or `RepoKey.other` for non-git bucket).
    public let key: String
    /// Human-friendly display name (last path component, or "Other").
    public let displayName: String
    /// True when this repo currently has at least one live agent session.
    public let hasActiveSessions: Bool

    public init(key: String, displayName: String, hasActiveSessions: Bool) {
        self.key = key
        self.displayName = displayName
        self.hasActiveSessions = hasActiveSessions
    }
}

/// Which agent runtime owns the session.
public enum AgentKind: String, Codable, Hashable, Sendable, CaseIterable {
    case claude
    case codex
}

/// Lifecycle phase of a session as seen by the daemon.
public enum AgentSessionStatus: String, Codable, Hashable, Sendable {
    /// Agent is in `--permission-mode plan` (Claude) or equivalent.
    case planning
    /// Agent is actively executing or awaiting user input in TUI.
    case running
    /// Paused (rate limit hit, user-requested, or detected idle).
    case paused
    /// Done-detector fired (D4) — agent reached its stated goal.
    case done
    /// tmux server lost / pane unknown; needs supervisor recovery.
    case degraded
}

/// Snapshot of one agent session for list / detail views.
public struct AgentSession: Codable, Hashable, Sendable, Identifiable {
    /// Server-assigned UUID. Used as `Identifiable.id` and as the URL
    /// segment in `/sessions/:id/*` endpoints.
    public let id: UUID
    /// The repo (canonical) the session is rooted in.
    public let repoKey: String
    /// Display label for the repo (denormalized for cheap list rendering).
    public let repoDisplayName: String
    /// Which agent CLI is running.
    public let agent: AgentKind
    /// Model identifier requested at spawn (e.g. "sonnet", "opus", "gpt-5.5").
    /// `nil` means default (whatever the CLI picks).
    public let model: String?
    /// User-supplied goal string. Used by D4 done-detector for signal (a)/(c).
    public let goal: String?
    /// When `useWorktree` was on at create, the absolute path of the
    /// `.claude/worktrees/<slug>` directory the agent runs inside.
    public let worktreePath: String?
    /// Underlying tmux window id (e.g. "@3"). `nil` while a session is
    /// pending or degraded.
    public let tmuxWindowId: String?
    /// Active tmux pane id within the window (e.g. "%5"). Used by the
    /// terminal WS bridge to target `send-keys` / `paste-buffer`.
    public let tmuxPaneId: String?
    /// Session lifecycle phase.
    public let status: AgentSessionStatus
    /// Plan text from Claude's last `ExitPlanMode` tool call. `nil` when
    /// the session is not in plan mode or no plan has been emitted yet.
    public let planText: String?
    /// Wall-clock when the session was created (server's local time, UTC).
    public let createdAt: Date
    /// Most recent event the server observed (heartbeat / message / tool call).
    public let lastEventAt: Date
    /// Highest `eventSeq` the registry has emitted for this session.
    public let lastEventSeq: UInt64

    public init(
        id: UUID,
        repoKey: String,
        repoDisplayName: String,
        agent: AgentKind,
        model: String?,
        goal: String?,
        worktreePath: String?,
        tmuxWindowId: String?,
        tmuxPaneId: String?,
        status: AgentSessionStatus,
        planText: String?,
        createdAt: Date,
        lastEventAt: Date,
        lastEventSeq: UInt64
    ) {
        self.id = id
        self.repoKey = repoKey
        self.repoDisplayName = repoDisplayName
        self.agent = agent
        self.model = model
        self.goal = goal
        self.worktreePath = worktreePath
        self.tmuxWindowId = tmuxWindowId
        self.tmuxPaneId = tmuxPaneId
        self.status = status
        self.planText = planText
        self.createdAt = createdAt
        self.lastEventAt = lastEventAt
        self.lastEventSeq = lastEventSeq
    }
}

// MARK: - Requests

/// `POST /sessions` body. Used by both Mac dashboard and iPhone Sessions tab.
public struct NewSessionRequest: Codable, Sendable {
    public let repoKey: String
    public let agent: AgentKind
    public let model: String?
    /// If true, daemon spawns Claude with `--permission-mode plan`.
    /// No-op for Codex (config already sets `approval_policy = "never"`).
    public let planMode: Bool
    /// Optional user-supplied goal. Required by D7 when `useWorktree=true`
    /// (to derive a slug for the worktree directory name).
    public let goal: String?
    /// If true, `WorktreeManager` runs `git worktree add` before spawning
    /// and the agent's cwd becomes the worktree path.
    public let useWorktree: Bool
    /// Base branch for the worktree. `nil` defaults to the repo's HEAD.
    public let baseBranch: String?

    public init(
        repoKey: String,
        agent: AgentKind,
        model: String? = nil,
        planMode: Bool = false,
        goal: String? = nil,
        useWorktree: Bool = false,
        baseBranch: String? = nil
    ) {
        self.repoKey = repoKey
        self.agent = agent
        self.model = model
        self.planMode = planMode
        self.goal = goal
        self.useWorktree = useWorktree
        self.baseBranch = baseBranch
    }
}

// MARK: - Pairing

/// QR-encoded pairing payload. Mac displays this; iPhone scans + parses.
///
/// Wire format: `clawdmeter://<host>:<port>?token=<base64url>` where the
/// path is empty. iPhone reconstructs this struct from the URL components.
public struct PairingChallenge: Codable, Sendable {
    /// MagicDNS host name (e.g. `darshans-macbook-pro.tail87a721.ts.net`).
    public let host: String
    /// HTTP port the daemon bound to (default 21731, may be 21732+ on conflict).
    public let port: Int
    /// 32-byte high-entropy bearer token, base64url-encoded.
    public let token: String

    public init(host: String, port: Int, token: String) {
        self.host = host
        self.port = port
        self.token = token
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

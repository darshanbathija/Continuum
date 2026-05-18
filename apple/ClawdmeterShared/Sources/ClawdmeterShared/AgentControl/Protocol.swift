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

// MARK: - Wire version (Sessions v2 E8)

/// Single source of truth for the wire-protocol revision. Bumped in lockstep
/// with breaking shape changes. v3 adds: `effort`, `abPairSessionId`,
/// `abPairDecidedAt` on `AgentSession`; `ReasoningEffort` + `ModelCatalog`
/// + mid-session change endpoints + `WireChatSnapshot` + `HealthResponse`.
///
/// iOS reads this on pair-test or session-list refresh and compares to its
/// own constant. Mismatch surfaces a banner. New endpoints return HTTP 426.
public enum AgentControlWireVersion {
    /// Wire version. Bump when adding a new WS op, REST endpoint, or DTO that
    /// older Macs won't recognize so iOS can fall back gracefully.
    /// v4 (2026-05-18) adds `compose-draft` WS op (X1 cross-Apple handoff).
    public static let current: Int = 4
    /// Minimum wire version that supports the `compose-draft` WS op.
    /// iOS guards `postComposeDraft` on this — older Macs would reject
    /// the unknown op via `.unsupportedData` close (review §10 finding).
    public static let composeDraftMinimum: Int = 4
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

// MARK: - Reasoning effort (CEO D11 / Sessions v2 Phase 0)

/// Per-session reasoning / thinking effort level. Same enum drives Claude
/// (`--effort`) and Codex (`-c model_reasoning_effort=`). UI shows it as a
/// 5-segment dial (Min · Low · Med · High · xHigh).
public enum ReasoningEffort: String, Codable, Hashable, Sendable, CaseIterable {
    case minimal
    case low
    case medium
    case high
    case xhigh
    case max

    /// Claude CLI flag value (`claude --effort <value>`, verified against
    /// claude --help 2.1.141 — exposes low/medium/high/xhigh/max).
    public var claudeFlagValue: String {
        switch self {
        case .minimal: return "low"   // claude CLI does not expose minimal — fold into low
        case .low:     return "low"
        case .medium:  return "medium"
        case .high:    return "high"
        case .xhigh:   return "xhigh"
        case .max:     return "max"
        }
    }

    /// Codex CLI config value (`codex -c model_reasoning_effort="<value>"`).
    /// Codex exposes the same five levels via TOML override; codex CLI does
    /// NOT have a `--reasoning-effort` flag, only this config-override path.
    /// `max` folds into `xhigh` for Codex (no equivalent override).
    public var codexConfigValue: String {
        switch self {
        case .max: return "xhigh"
        default:   return rawValue
        }
    }

    /// Lenient decoder: unknown raw values (older Macs reading a `max`
    /// effort written by a newer Mac) decode to `.xhigh` rather than
    /// failing the whole AgentSession Codable round-trip.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = ReasoningEffort(rawValue: raw) ?? .xhigh
    }
}

// MARK: - Permission mode

/// Claude-Code-style permission tiers. Each tier maps cleanly to a
/// supported CLI flag — we DON'T expose modes the CLIs can't enforce.
///
/// - `ask`: default. Agent asks before every tool call.
///   - Claude: no flag.
///   - Codex: no flag (defaults to workspace-write asking before non-trivial ops).
/// - `acceptEdits`: agent auto-accepts file edits/writes, still asks for
///   Bash and other non-edit tool calls.
///   - Claude: `--permission-mode acceptEdits`.
///   - Codex: no exact equivalent; folds into `ask` (default workspace-write
///     already auto-accepts in-workspace writes).
/// - `plan`: agent runs read-only until the user approves the plan.
///   - Claude: `--permission-mode plan`.
///   - Codex: `-s read-only`.
/// - `bypass`: skip every permission check. Per-repo trust required.
///   - Claude: `--dangerously-skip-permissions`.
///   - Codex: `--dangerously-bypass-approvals-and-sandbox`.
public enum PermissionMode: String, Codable, Hashable, Sendable, CaseIterable {
    case ask
    case acceptEdits
    case plan
    case bypass

    /// User-facing label, matches the wording in the Mac composer's
    /// mode menu.
    public var displayName: String {
        switch self {
        case .ask:         return "Ask permissions"
        case .acceptEdits: return "Accept edits"
        case .plan:        return "Plan mode"
        case .bypass:      return "Bypass permissions"
        }
    }

    /// Short label used on the chip itself.
    public var shortLabel: String {
        switch self {
        case .ask:         return "Ask"
        case .acceptEdits: return "Accept edits"
        case .plan:        return "Plan"
        case .bypass:      return "Bypass"
        }
    }

    /// Whether picking this mode requires a per-repo trust grant
    /// (handled by the existing `AutopilotState.trustRepo` path).
    public var requiresTrust: Bool {
        self == .bypass
    }

    /// Lenient decoder for forward-compat with future-Mac modes.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = PermissionMode(rawValue: raw) ?? .ask
    }
}

// MARK: - Model catalog (Sessions v2 Phase 0)

/// One model the user can pick in the per-session model picker. Bundled
/// into `ClawdmeterShared` and served by `GET /models`.
public struct ModelCatalogEntry: Codable, Hashable, Sendable, Identifiable {
    public let id: String                 // e.g. "claude-opus-4-7-1m", "gpt-5.5"
    public let provider: AgentKind
    public let displayName: String        // e.g. "Opus 4.7 1M"
    public let cliAlias: String?          // claude CLI shorthand (opus / sonnet / haiku) when applicable
    public let supportsThinking: Bool     // Claude extended-thinking capable
    public let supportsEffort: Bool       // accepts a non-default effort level
    public let contextWindow: Int?        // 1_000_000 for "1M" variants, else nil
    public let recommendedFor: String?    // "Plan mode", "Fast iteration"
    public let badge: String?             // "New", "1M", "Fast"

    public init(
        id: String,
        provider: AgentKind,
        displayName: String,
        cliAlias: String? = nil,
        supportsThinking: Bool = true,
        supportsEffort: Bool = true,
        contextWindow: Int? = nil,
        recommendedFor: String? = nil,
        badge: String? = nil
    ) {
        self.id = id
        self.provider = provider
        self.displayName = displayName
        self.cliAlias = cliAlias
        self.supportsThinking = supportsThinking
        self.supportsEffort = supportsEffort
        self.contextWindow = contextWindow
        self.recommendedFor = recommendedFor
        self.badge = badge
    }
}

public struct ModelCatalog: Codable, Sendable {
    public let claude: [ModelCatalogEntry]
    public let codex: [ModelCatalogEntry]
    public let updatedAt: Date

    public init(claude: [ModelCatalogEntry], codex: [ModelCatalogEntry], updatedAt: Date) {
        self.claude = claude
        self.codex = codex
        self.updatedAt = updatedAt
    }

    /// Bundled default catalog. Mirrors the user's Conductor screenshot:
    /// Opus 4.7 / Opus 4.7 1M / Opus 4.6 1M / Sonnet 4.6 / Haiku 4.5 +
    /// GPT-5.5 / GPT-5.4 / GPT-5.3-Codex-Spark / GPT-5.3-Codex / GPT-5.2-Codex.
    public static let bundled = ModelCatalog(
        claude: [
            ModelCatalogEntry(id: "claude-opus-4-7-1m",        provider: .claude, displayName: "Opus 4.7 (1M)",   cliAlias: nil,      supportsThinking: true,  supportsEffort: true,  contextWindow: 1_000_000, recommendedFor: "Long tasks",     badge: "1M"),
            ModelCatalogEntry(id: "claude-opus-4-7",           provider: .claude, displayName: "Opus 4.7",        cliAlias: "opus",   supportsThinking: true,  supportsEffort: true,  contextWindow: 200_000,   recommendedFor: "Most work",      badge: "New"),
            ModelCatalogEntry(id: "claude-opus-4-6-1m",        provider: .claude, displayName: "Opus 4.6 (1M)",   cliAlias: nil,      supportsThinking: true,  supportsEffort: true,  contextWindow: 1_000_000, recommendedFor: nil,              badge: "1M"),
            ModelCatalogEntry(id: "claude-sonnet-4-6",         provider: .claude, displayName: "Sonnet 4.6",      cliAlias: "sonnet", supportsThinking: true,  supportsEffort: true,  contextWindow: 200_000,   recommendedFor: "Plan mode",      badge: nil),
            ModelCatalogEntry(id: "claude-haiku-4-5-20251001", provider: .claude, displayName: "Haiku 4.5",       cliAlias: "haiku",  supportsThinking: false, supportsEffort: false, contextWindow: 200_000,   recommendedFor: "PR titles",      badge: "Fast"),
        ],
        codex: [
            ModelCatalogEntry(id: "gpt-5.5",             provider: .codex, displayName: "GPT-5.5",              cliAlias: nil, supportsThinking: false, supportsEffort: true, contextWindow: nil, recommendedFor: "Most work",      badge: "New"),
            ModelCatalogEntry(id: "gpt-5.4",             provider: .codex, displayName: "GPT-5.4",              cliAlias: nil, supportsThinking: false, supportsEffort: true, contextWindow: nil, recommendedFor: nil,              badge: nil),
            ModelCatalogEntry(id: "gpt-5.3-codex-spark", provider: .codex, displayName: "GPT-5.3 Codex Spark",  cliAlias: nil, supportsThinking: false, supportsEffort: true, contextWindow: nil, recommendedFor: "Fast iteration", badge: "Fast"),
            ModelCatalogEntry(id: "gpt-5.3-codex",       provider: .codex, displayName: "GPT-5.3 Codex",        cliAlias: nil, supportsThinking: false, supportsEffort: true, contextWindow: nil, recommendedFor: nil,              badge: nil),
            ModelCatalogEntry(id: "gpt-5.2-codex",       provider: .codex, displayName: "GPT-5.2 Codex",        cliAlias: nil, supportsThinking: false, supportsEffort: true, contextWindow: nil, recommendedFor: nil,              badge: nil),
        ],
        updatedAt: Date(timeIntervalSince1970: 1747353600) // 2026-05-15
    )

    /// Resolve a model id to a catalog entry across both providers.
    public func entry(forId id: String) -> ModelCatalogEntry? {
        claude.first(where: { $0.id == id || $0.cliAlias == id })
            ?? codex.first(where: { $0.id == id || $0.cliAlias == id })
    }
}

// MARK: - Repo + Session

/// One session JSONL file that wasn't spawned by Clawdmeter but lived in a
/// repo we know about. Surfaced in the sidebar so the user can revisit any
/// past Claude / Codex session as read-only chat.
public struct RecentSession: Codable, Hashable, Sendable, Identifiable {
    /// Absolute path to the JSONL on disk. Doubles as our stable id —
    /// JSONL files don't move once written.
    public let path: String
    /// Most recent mtime we observed (for sorting + "X ago" label).
    public let lastModified: Date
    /// Which provider wrote this JSONL.
    public let provider: AgentKind
    /// First user prompt extracted from the JSONL. Used as the sidebar row
    /// title so a list of past sessions reads like a list of intents
    /// instead of "Claude session" five times in a row. Optional —
    /// empty / parse-failed JSONLs fall back to the generic label.
    public let firstPrompt: String?
    public var id: String { path }

    public init(
        path: String,
        lastModified: Date,
        provider: AgentKind,
        firstPrompt: String? = nil
    ) {
        self.path = path
        self.lastModified = lastModified
        self.provider = provider
        self.firstPrompt = firstPrompt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.path = try c.decode(String.self, forKey: .path)
        self.lastModified = try c.decode(Date.self, forKey: .lastModified)
        self.provider = try c.decode(AgentKind.self, forKey: .provider)
        self.firstPrompt = try c.decodeIfPresent(String.self, forKey: .firstPrompt)
    }

    private enum CodingKeys: String, CodingKey {
        case path, lastModified, provider, firstPrompt
    }
}

// MARK: - Sidebar grouping / sorting

/// How the Sessions sidebar buckets rows. Repo is the legacy default
/// (one section per cwd). Date / Status / Agent flatten across repos and
/// re-bucket by the chosen field. None renders a flat list.
public enum SessionGrouping: String, Codable, CaseIterable, Sendable {
    case repo
    case date
    case status
    case agent
    case none

    public var displayName: String {
        switch self {
        case .repo:   return "Repo"
        case .date:   return "Date"
        case .status: return "Status"
        case .agent:  return "Agent"
        case .none:   return "None"
        }
    }
}

/// Sort order within each group.
public enum SessionSorting: String, Codable, CaseIterable, Sendable {
    case recency
    case created
    case name

    public var displayName: String {
        switch self {
        case .recency: return "Recency"
        case .created: return "Created"
        case .name:    return "Name"
        }
    }
}

/// Status filter. `.all` shows everything; `.active` keeps planning + running +
/// paused; `.done` keeps done; `.archived` keeps archived-only (the existing
/// `showArchived` toggle still wins for backwards compat).
public enum SessionStatusFilter: String, Codable, CaseIterable, Sendable {
    case all
    case active
    case done
    case archived

    public var displayName: String {
        switch self {
        case .all:      return "All"
        case .active:   return "Active"
        case .done:     return "Done"
        case .archived: return "Archived"
        }
    }
}

/// Stable identifier for a repo, mirrors `RepoKey` from the existing
/// Analytics layer. Use `RepoIdentity.normalize(_:)` to convert raw cwds.
public struct AgentRepo: Codable, Hashable, Sendable {
    /// Canonical repo path (or `RepoKey.other` for non-git bucket).
    public let key: String
    /// Human-friendly display name (last path component, or "Other").
    public let displayName: String
    /// True when this repo currently has at least one live agent session
    /// (one Clawdmeter spawned). Distinct from `liveSessionCount`.
    public let hasActiveSessions: Bool
    /// Count of session JSONLs under this repo with mtime within the last
    /// 5 minutes — agents actively writing RIGHT NOW. This is the narrow
    /// "live now" signal (green dot in UI). Optional (default 0) so old
    /// wire stays valid.
    public let liveSessionCount: Int
    /// Sessions (outside-Clawdmeter) that wrote to disk within the recent
    /// activity window (30 days by default). Each entry is one JSONL the
    /// user can open as read-only chat. Sorted newest-first.
    public let recentSessions: [RecentSession]

    public init(
        key: String,
        displayName: String,
        hasActiveSessions: Bool,
        liveSessionCount: Int = 0,
        recentSessions: [RecentSession] = []
    ) {
        self.key = key
        self.displayName = displayName
        self.hasActiveSessions = hasActiveSessions
        self.liveSessionCount = liveSessionCount
        self.recentSessions = recentSessions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.key = try c.decode(String.self, forKey: .key)
        self.displayName = try c.decode(String.self, forKey: .displayName)
        self.hasActiveSessions = try c.decode(Bool.self, forKey: .hasActiveSessions)
        self.liveSessionCount = (try? c.decode(Int.self, forKey: .liveSessionCount)) ?? 0
        self.recentSessions = (try? c.decodeIfPresent([RecentSession].self, forKey: .recentSessions)) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case key, displayName, hasActiveSessions, liveSessionCount, recentSessions
    }
}

/// Which agent runtime owns the session.
public enum AgentKind: String, Codable, Hashable, Sendable, CaseIterable {
    case claude
    case codex
}

/// Where the session executes — the Codex-desktop "mode picker" axis.
/// Switching mode on a live session triggers a restart in the new cwd
/// (D13 overlay flow). Wire-stable: new variants append.
public enum SessionMode: String, Codable, Hashable, Sendable, CaseIterable {
    /// Run in the repo's primary checkout. Edits land directly.
    case local
    /// Run inside `.claude/worktrees/<slug>` (git worktree branched off main).
    /// Same repo, isolated working tree.
    case worktree
    /// Reserved for future remote-Mac federation (G20). Disabled in v1 UI.
    case cloud
}

// MARK: - Multi-terminal (G12)

/// One tmux pane belonging to a session. A session can own N panes — the
/// primary pane runs the agent CLI, secondary panes are shell scratch space
/// the user spawns from the workspace's terminal tab strip.
public struct TerminalPaneRef: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    /// tmux pane identifier (e.g. "%7"). Targets `send-keys` / `paste-buffer`.
    public let paneId: String
    /// User-facing label. Empty = "Pane <index>".
    public let title: String
    /// True when this is the agent's primary pane (created at spawn time).
    /// Primary pane can't be deleted via the tab strip's × button.
    public let isPrimary: Bool
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        paneId: String,
        title: String = "",
        isPrimary: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.paneId = paneId
        self.title = title
        self.isPrimary = isPrimary
        self.createdAt = createdAt
    }
}

// MARK: - Scheduled follow-ups (G15)

/// One scheduled prompt that the SessionScheduler will inject into the
/// session's primary tmux pane at `fireAt`. Persisted so they survive
/// app restarts; on launch the scheduler re-arms timers for any not-yet-
/// fired entries.
public struct ScheduledFollowUp: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    /// Wall-clock when the prompt should fire.
    public let fireAt: Date
    /// The literal text injected into the agent's input.
    public let prompt: String
    /// When the scheduler actually delivered the prompt. `nil` until then.
    public let firedAt: Date?

    public init(
        id: UUID = UUID(),
        fireAt: Date,
        prompt: String,
        firedAt: Date? = nil
    ) {
        self.id = id
        self.fireAt = fireAt
        self.prompt = prompt
        self.firedAt = firedAt
    }
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
    /// Where this session is running (Local vs Worktree). Optional in the
    /// Codable for backward-compat: sessions persisted before G0 default
    /// to `.worktree` if `worktreePath != nil`, otherwise `.local`.
    public let mode: SessionMode
    /// When the user archived this session. `nil` = active. Archived sessions
    /// are hidden from the default sidebar but recoverable via "Show archived".
    /// Done-detector auto-archives sessions older than the configured threshold.
    public let archivedAt: Date?
    /// Additional tmux panes spawned via the workspace terminal tab strip.
    /// The primary pane lives at `tmuxPaneId`; this collection is everything
    /// else. Empty for pre-G2 sessions (decoded as `[]`).
    public let terminalPanes: [TerminalPaneRef]
    /// Pending follow-up prompts scheduled by the user; the SessionScheduler
    /// fires them and writes back into the session via `paste-buffer`.
    public let scheduledFollowUps: [ScheduledFollowUp]
    /// If this session was spawned as a sub-chat (Cmd+;), the id of the
    /// parent session. Sidebar nests sub-rows under the parent.
    public let parentSessionId: UUID?

    // MARK: - Sessions v2 schema v3 additions
    //
    // All three optional + decoder-tolerant so v2 sessions.json files
    // decode cleanly. Downgrade path: v2 reader silently drops these
    // fields — documented in CLAUDE.md.

    /// Reasoning / thinking effort level requested at spawn (or after
    /// mid-session swap). `nil` = CLI default.
    public let effort: ReasoningEffort?
    /// When this session is one half of an A/B agent pair, the id of the
    /// sibling. Clearing this field (on archive of one sibling) promotes
    /// the survivor to standalone with a banner per D16.
    public let abPairSessionId: UUID?
    /// Atomic CAS lock on A/B-pair winner-pick (E3). First request wins;
    /// second request sees this populated and gets 409. `nil` until
    /// someone picks a winner; cleared on un-pair.
    public let abPairDecidedAt: Date?

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
        lastEventSeq: UInt64,
        mode: SessionMode = .local,
        archivedAt: Date? = nil,
        terminalPanes: [TerminalPaneRef] = [],
        scheduledFollowUps: [ScheduledFollowUp] = [],
        parentSessionId: UUID? = nil,
        effort: ReasoningEffort? = nil,
        abPairSessionId: UUID? = nil,
        abPairDecidedAt: Date? = nil
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
        self.mode = mode
        self.archivedAt = archivedAt
        self.terminalPanes = terminalPanes
        self.scheduledFollowUps = scheduledFollowUps
        self.parentSessionId = parentSessionId
        self.effort = effort
        self.abPairSessionId = abPairSessionId
        self.abPairDecidedAt = abPairDecidedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.repoKey = try c.decode(String.self, forKey: .repoKey)
        self.repoDisplayName = try c.decode(String.self, forKey: .repoDisplayName)
        self.agent = try c.decode(AgentKind.self, forKey: .agent)
        self.model = try c.decodeIfPresent(String.self, forKey: .model)
        self.goal = try c.decodeIfPresent(String.self, forKey: .goal)
        self.worktreePath = try c.decodeIfPresent(String.self, forKey: .worktreePath)
        self.tmuxWindowId = try c.decodeIfPresent(String.self, forKey: .tmuxWindowId)
        self.tmuxPaneId = try c.decodeIfPresent(String.self, forKey: .tmuxPaneId)
        self.status = try c.decode(AgentSessionStatus.self, forKey: .status)
        self.planText = try c.decodeIfPresent(String.self, forKey: .planText)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.lastEventAt = try c.decode(Date.self, forKey: .lastEventAt)
        self.lastEventSeq = try c.decode(UInt64.self, forKey: .lastEventSeq)
        // mode: if absent, infer from worktreePath (back-compat with v1).
        if let decoded = try? c.decodeIfPresent(SessionMode.self, forKey: .mode) {
            self.mode = decoded
        } else {
            self.mode = self.worktreePath != nil ? .worktree : .local
        }
        self.archivedAt = try c.decodeIfPresent(Date.self, forKey: .archivedAt)
        self.terminalPanes = (try? c.decodeIfPresent([TerminalPaneRef].self, forKey: .terminalPanes)) ?? []
        self.scheduledFollowUps = (try? c.decodeIfPresent([ScheduledFollowUp].self, forKey: .scheduledFollowUps)) ?? []
        self.parentSessionId = try c.decodeIfPresent(UUID.self, forKey: .parentSessionId)
        // Schema v3 fields: optional + decoder-tolerant so v2 files decode.
        self.effort = (try? c.decodeIfPresent(ReasoningEffort.self, forKey: .effort)) ?? nil
        self.abPairSessionId = (try? c.decodeIfPresent(UUID.self, forKey: .abPairSessionId)) ?? nil
        self.abPairDecidedAt = (try? c.decodeIfPresent(Date.self, forKey: .abPairDecidedAt)) ?? nil
    }

    private enum CodingKeys: String, CodingKey {
        case id, repoKey, repoDisplayName, agent, model, goal,
             worktreePath, tmuxWindowId, tmuxPaneId,
             status, planText, createdAt, lastEventAt, lastEventSeq,
             mode, archivedAt,
             terminalPanes, scheduledFollowUps, parentSessionId,
             effort, abPairSessionId, abPairDecidedAt
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
    /// Per-session reasoning effort. `nil` = CLI default. Sessions v2 D3.
    public let effort: ReasoningEffort?
    /// If non-nil, spawn this session AND a sibling using `abPair` as the
    /// second agent (the same goal/model/effort, in a sibling worktree).
    /// Phase 7 dmux feature.
    public let abPair: AgentKind?

    public init(
        repoKey: String,
        agent: AgentKind,
        model: String? = nil,
        planMode: Bool = false,
        goal: String? = nil,
        useWorktree: Bool = false,
        baseBranch: String? = nil,
        effort: ReasoningEffort? = nil,
        abPair: AgentKind? = nil
    ) {
        self.repoKey = repoKey
        self.agent = agent
        self.model = model
        self.planMode = planMode
        self.goal = goal
        self.useWorktree = useWorktree
        self.baseBranch = baseBranch
        self.effort = effort
        self.abPair = abPair
    }

    // Custom decoder to tolerate v2 requests missing the new fields.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.repoKey = try c.decode(String.self, forKey: .repoKey)
        self.agent = try c.decode(AgentKind.self, forKey: .agent)
        self.model = try c.decodeIfPresent(String.self, forKey: .model)
        self.planMode = (try? c.decode(Bool.self, forKey: .planMode)) ?? false
        self.goal = try c.decodeIfPresent(String.self, forKey: .goal)
        self.useWorktree = (try? c.decode(Bool.self, forKey: .useWorktree)) ?? false
        self.baseBranch = try c.decodeIfPresent(String.self, forKey: .baseBranch)
        self.effort = try c.decodeIfPresent(ReasoningEffort.self, forKey: .effort)
        self.abPair = try c.decodeIfPresent(AgentKind.self, forKey: .abPair)
    }

    private enum CodingKeys: String, CodingKey {
        case repoKey, agent, model, planMode, goal, useWorktree, baseBranch, effort, abPair
    }
}

// MARK: - Mid-session change requests (Sessions v2 Phase 0)

/// `POST /sessions/:id/model` body. Mid-session model swap.
public struct ChangeModelRequest: Codable, Sendable {
    public let model: String
    /// Optional new effort to apply together with the model swap. If nil,
    /// existing effort is preserved.
    public let effort: ReasoningEffort?

    public init(model: String, effort: ReasoningEffort? = nil) {
        self.model = model
        self.effort = effort
    }
}

/// `POST /sessions/:id/mode` body. Mid-session mode change (local/worktree;
/// `.cloud` rejected with 400). Optional plan-mode flip alongside.
public struct ChangeModeRequest: Codable, Sendable {
    public let mode: SessionMode
    /// Claude-only. Ignored for Codex.
    public let planMode: Bool?

    public init(mode: SessionMode, planMode: Bool? = nil) {
        self.mode = mode
        self.planMode = planMode
    }
}

/// `POST /sessions/:id/effort` body. Effort-only swap (cheaper than model
/// swap; still triggers respawn).
public struct ChangeEffortRequest: Codable, Sendable {
    public let effort: ReasoningEffort

    public init(effort: ReasoningEffort) {
        self.effort = effort
    }
}

/// `POST /sessions/:id/send` body. Inject a prompt into the running agent's
/// tmux pane. >256 bytes uses paste-buffer; otherwise send-keys.
public struct SendPromptRequest: Codable, Sendable {
    public let text: String
    /// If true, the daemon writes to tmux paste-buffer + pastes (good for
    /// multi-line / IME / large content). If false, plain send-keys.
    public let asFollowUp: Bool

    public init(text: String, asFollowUp: Bool = true) {
        self.text = text
        self.asFollowUp = asFollowUp
    }
}

/// `POST /sessions/continue-readonly` body. Used by the iOS app to promote
/// a Recent JSONL row (outside Clawdmeter) into a live Clawdmeter-owned
/// session and optionally send a first prompt — the same flow the Mac runs
/// inline via `SessionsModel.continueCurrentReadOnly`. The daemon parses
/// the JSONL header for the CLI session id, spawns a fresh tmux pane with
/// `--resume <id>` (Claude) or `resume <id>` (Codex), and returns the new
/// AgentSession's id.
public struct ContinueReadOnlyRequest: Codable, Sendable {
    /// Absolute path to the JSONL on the Mac. Stable id for the outside
    /// session (`RecentSession.path`).
    public let jsonlPath: String
    /// Repo key the session belongs to. Canonical normalized cwd.
    public let repoKey: String
    /// Which CLI wrote this JSONL — drives spawn argv + JSONL parser shape.
    public let agent: AgentKind
    /// Optional first prompt. When non-empty, the daemon posts it after the
    /// pane is ready. Clients can also leave this nil and post separately
    /// via `POST /sessions/:id/send` once the new session id is returned.
    public let prompt: String?

    public init(jsonlPath: String, repoKey: String, agent: AgentKind, prompt: String? = nil) {
        self.jsonlPath = jsonlPath
        self.repoKey = repoKey
        self.agent = agent
        self.prompt = prompt
    }
}

/// `POST /sessions/continue-readonly` response. Carries the new live
/// session id so the client can swap its open-state from the outside
/// JSONL path to the live `AgentSession`.
public struct ContinueReadOnlyResponse: Codable, Sendable {
    public let sessionId: UUID

    public init(sessionId: UUID) {
        self.sessionId = sessionId
    }
}

/// `POST /sessions/:id/attachments?ext=png` response.
///
/// Body of the request is raw image bytes. The daemon writes them to
/// the session's staging directory (`~/Library/Application Support/
/// Clawdmeter/attachments/<sessionId>/<uuid>.<ext>` for Claude / Codex-
/// local, or `<worktree>/.clawdmeter-attachments/` when Codex is in
/// worktree mode), and returns the absolute path the agent can read
/// via `@<path>`. Lets iOS attach images from the camera roll without
/// shipping the bytes back to itself.
public struct UploadAttachmentResponse: Codable, Sendable {
    public let id: UUID
    public let path: String

    public init(id: UUID, path: String) {
        self.id = id
        self.path = path
    }
}

/// `POST /sessions/:id/autopilot` body. NO re-auth (D14). Each toggle
/// writes an audit log entry. Per E7: enabling adds 15-min inactivity
/// timeout + per-repo trust list + red banner across surfaces.
public struct AutopilotRequest: Codable, Sendable {
    public let enabled: Bool

    public init(enabled: Bool) {
        self.enabled = enabled
    }
}

/// `POST /sessions/:id/ab-pair/pick-winner` body + response. Atomic CAS
/// via daemon (E3): first request locks `abPairDecidedAt`; second returns
/// 409 with the winning sibling id.
public struct PickWinnerRequest: Codable, Sendable {
    public let winnerSessionId: UUID

    public init(winnerSessionId: UUID) {
        self.winnerSessionId = winnerSessionId
    }
}

/// Returned on 409 from pick-winner when the pair is already decided.
public struct PickWinnerConflictResponse: Codable, Sendable {
    public let alreadyDecided: Bool
    public let winnerSessionId: UUID
    public let decidedAt: Date

    public init(winnerSessionId: UUID, decidedAt: Date) {
        self.alreadyDecided = true
        self.winnerSessionId = winnerSessionId
        self.decidedAt = decidedAt
    }
}

// MARK: - PR + Diff DTOs (Sessions v2 Phase 4)

/// `GET /sessions/:id/pr` response. nil = no PR yet (offer Create).
public struct PRStatus: Codable, Sendable {
    public enum State: String, Codable, Sendable {
        case open, merged, closed, draft
    }

    public let url: String
    public let number: Int
    public let title: String
    public let body: String
    public let state: State
    public let additions: Int
    public let deletions: Int
    public let changedFiles: Int
    /// Approve / request-changes / pending / null. From `gh pr view --json`.
    public let reviewDecision: String?
    /// CI checks rolled up: "success" / "pending" / "failure" / null.
    public let checksRollup: String?

    public init(
        url: String,
        number: Int,
        title: String,
        body: String,
        state: State,
        additions: Int = 0,
        deletions: Int = 0,
        changedFiles: Int = 0,
        reviewDecision: String? = nil,
        checksRollup: String? = nil
    ) {
        self.url = url
        self.number = number
        self.title = title
        self.body = body
        self.state = state
        self.additions = additions
        self.deletions = deletions
        self.changedFiles = changedFiles
        self.reviewDecision = reviewDecision
        self.checksRollup = checksRollup
    }
}

public struct CreatePRRequest: Codable, Sendable {
    public let title: String?       // nil = AI-generate via Haiku 4.5
    public let body: String?        // nil = AI-generate
    public let baseBranch: String?  // nil = repo default

    public init(title: String? = nil, body: String? = nil, baseBranch: String? = nil) {
        self.title = title
        self.body = body
        self.baseBranch = baseBranch
    }
}

/// One file's diff. `hunks` may be empty when the file is too large to
/// inline; the iOS view shows "see full" CTA.
public struct GitDiffFile: Codable, Sendable, Identifiable {
    public var id: String { path }
    public let path: String
    public let oldPath: String?     // present on renames
    public let status: String       // "A" / "M" / "D" / "R" / "C"
    public let additions: Int
    public let deletions: Int
    public let hunks: [GitDiffHunk]
    public let truncated: Bool

    public init(
        path: String,
        oldPath: String? = nil,
        status: String,
        additions: Int,
        deletions: Int,
        hunks: [GitDiffHunk] = [],
        truncated: Bool = false
    ) {
        self.path = path
        self.oldPath = oldPath
        self.status = status
        self.additions = additions
        self.deletions = deletions
        self.hunks = hunks
        self.truncated = truncated
    }
}

public struct GitDiffHunk: Codable, Sendable {
    public let header: String       // @@ -a,b +c,d @@
    public let lines: [Line]

    public struct Line: Codable, Sendable {
        public enum Kind: String, Codable, Sendable { case context, addition, deletion }
        public let kind: Kind
        public let text: String
        public init(kind: Kind, text: String) {
            self.kind = kind
            self.text = text
        }
    }

    public init(header: String, lines: [Line]) {
        self.header = header
        self.lines = lines
    }
}

// MARK: - Preflight cost + rate-limit gate (Phase 8 / D3)

public struct PreflightQuery: Codable, Sendable {
    public let repoKey: String
    public let agent: AgentKind
    public let model: String
    public let effort: ReasoningEffort?
    public let goalLength: Int      // characters, for token-count estimate

    public init(repoKey: String, agent: AgentKind, model: String, effort: ReasoningEffort?, goalLength: Int) {
        self.repoKey = repoKey
        self.agent = agent
        self.model = model
        self.effort = effort
        self.goalLength = goalLength
    }
}

public struct PreflightResponse: Codable, Sendable {
    /// Estimated USD cost for the session. Best-effort from past sessions
    /// of the same model on this repo. nil if no history.
    public let estimatedCostUSD: Double?
    /// Estimated weekly-cap consumption percentage (0.0–1.0). nil if data
    /// is missing or stale.
    public let weeklyCapPct: Double?
    /// True when this session at this model/effort would push weekly usage
    /// over the cap. UI shows the soft-warn banner (D11).
    public let wouldCap: Bool
    /// Suggested alternative model id when wouldCap == true. nil otherwise.
    public let suggestedSwap: String?
    /// True when the underlying usage snapshot is older than 1 hour.
    public let staleData: Bool

    public init(
        estimatedCostUSD: Double? = nil,
        weeklyCapPct: Double? = nil,
        wouldCap: Bool = false,
        suggestedSwap: String? = nil,
        staleData: Bool = false
    ) {
        self.estimatedCostUSD = estimatedCostUSD
        self.weeklyCapPct = weeklyCapPct
        self.wouldCap = wouldCap
        self.suggestedSwap = suggestedSwap
        self.staleData = staleData
    }
}

// MARK: - Wire chat snapshot (F2/F8 from main-reconciliation)

/// Cross-platform mirror of the Mac-side `SessionChatStore.ChatSnapshot`.
/// Reuses `ChatItem`, `PlanStep`, `SourceEntry`, `ArtifactEntry` (all
/// already in Shared via `ChatItemBuilder.swift`).
///
/// Wire path: `GET /sessions/:id/chat-snapshot[?since=<updateCounter>]`
/// returns the latest snapshot. WS subscription with envelope
/// `{op: "chat-snapshot", sessionId: <UUID>}` pushes deltas keyed on
/// `updateCounter` (monotonic per session).
public struct WireChatSnapshot: Codable, Sendable, Hashable {
    public let sessionId: UUID
    public let items: [ChatItem]
    public let planSteps: [PlanStep]
    public let sourceEntries: [SourceEntry]
    public let artifactEntries: [ArtifactEntry]
    public let totalInputTokens: Int
    public let totalOutputTokens: Int
    public let cacheReadTokens: Int
    public let cacheCreationTokens: Int
    public let lastEventAt: Date?
    public let updateCounter: UInt64

    public init(
        sessionId: UUID,
        items: [ChatItem],
        planSteps: [PlanStep],
        sourceEntries: [SourceEntry],
        artifactEntries: [ArtifactEntry],
        totalInputTokens: Int,
        totalOutputTokens: Int,
        cacheReadTokens: Int = 0,
        cacheCreationTokens: Int = 0,
        lastEventAt: Date?,
        updateCounter: UInt64
    ) {
        self.sessionId = sessionId
        self.items = items
        self.planSteps = planSteps
        self.sourceEntries = sourceEntries
        self.artifactEntries = artifactEntries
        self.totalInputTokens = totalInputTokens
        self.totalOutputTokens = totalOutputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.lastEventAt = lastEventAt
        self.updateCounter = updateCounter
    }
}

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

    public init(host: String, port: Int, wsPort: Int, token: String) {
        self.host = host
        self.port = port
        self.wsPort = wsPort
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

// MARK: - Usage envelope

/// Response shape for `GET /usage`. Carries the latest Claude + Codex
/// UsageData snapshots the Mac daemon has from its in-process pollers.
/// Replaces the iCloud-KV-sync path on iOS for users without a paid
/// Apple Developer entitlement — the iPhone just polls this every 30s
/// from the same paired Tailscale connection it uses for Sessions.
public struct UsageEnvelope: Codable, Sendable {
    public let claude: UsageData?
    public let codex: UsageData?
    /// Server-side wall-clock when the snapshot was assembled. The
    /// iPhone uses this to age the gauges ("Last checked X ago") so
    /// the user knows when the Mac last actually polled the providers.
    public let lastChecked: Date

    public init(claude: UsageData?, codex: UsageData?, lastChecked: Date) {
        self.claude = claude
        self.codex = codex
        self.lastChecked = lastChecked
    }
}

// MARK: - Compose-draft (X1 cross-Apple handoff)

/// Cross-Apple draft posted by iPhone "Open on Mac". The Mac dashboard
/// listens for these on the daemon's `compose-draft` WS op (added to
/// `AgentControlServer`'s first-message dispatcher 2026-05-18), and the
/// new empty-state centered composer pre-fills its fields. No new session
/// is created until the user actually hits send on the Mac side.
public struct ComposeDraft: Codable, Sendable, Equatable, Hashable {
    public let text: String
    public let repoKey: String?
    public let suggestedAgent: AgentKind?
    public let suggestedModel: String?
    public let suggestedEffort: ReasoningEffort?
    public let createdAt: Date

    public init(
        text: String,
        repoKey: String? = nil,
        suggestedAgent: AgentKind? = nil,
        suggestedModel: String? = nil,
        suggestedEffort: ReasoningEffort? = nil,
        createdAt: Date = Date()
    ) {
        self.text = text
        self.repoKey = repoKey
        self.suggestedAgent = suggestedAgent
        self.suggestedModel = suggestedModel
        self.suggestedEffort = suggestedEffort
        self.createdAt = createdAt
    }

    /// Serialize for inclusion as a nested JSON object inside the WS
    /// envelope's `draft` field. Returns `[:]` on encode failure (which
    /// shouldn't happen for an all-primitives struct).
    public func encodedJSONObject() -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }
}

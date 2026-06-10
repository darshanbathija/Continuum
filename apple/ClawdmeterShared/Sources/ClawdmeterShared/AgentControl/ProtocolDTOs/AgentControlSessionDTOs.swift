import Foundation

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
    /// Provenance of the scheduled prompt. Older persisted follow-ups decode
    /// as legacy and require confirmation so they cannot silently spend quota
    /// after an app update/relaunch.
    public let origin: ProviderPromptOrigin
    public let createdAt: Date
    public let createdBy: String
    public let deliveryPolicy: ScheduledFollowUpDeliveryPolicy

    public init(
        id: UUID = UUID(),
        fireAt: Date,
        prompt: String,
        firedAt: Date? = nil,
        origin: ProviderPromptOrigin = .scheduledUserFollowUp,
        createdAt: Date = Date(),
        createdBy: String = "user",
        deliveryPolicy: ScheduledFollowUpDeliveryPolicy = .autonomousAfterRestart
    ) {
        self.id = id
        self.fireAt = fireAt
        self.prompt = prompt
        self.firedAt = firedAt
        self.origin = origin
        self.createdAt = createdAt
        self.createdBy = createdBy
        self.deliveryPolicy = deliveryPolicy
    }

    private enum CodingKeys: String, CodingKey {
        case id, fireAt, prompt, firedAt, origin, createdAt, createdBy, deliveryPolicy
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        fireAt = try c.decode(Date.self, forKey: .fireAt)
        prompt = try c.decode(String.self, forKey: .prompt)
        firedAt = try c.decodeIfPresent(Date.self, forKey: .firedAt)
        origin = try c.decodeIfPresent(ProviderPromptOrigin.self, forKey: .origin) ?? .legacyClient
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? fireAt
        createdBy = try c.decodeIfPresent(String.self, forKey: .createdBy) ?? "legacy"
        deliveryPolicy = try c.decodeIfPresent(ScheduledFollowUpDeliveryPolicy.self, forKey: .deliveryPolicy)
            ?? .requiresConfirmation
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(fireAt, forKey: .fireAt)
        try c.encode(prompt, forKey: .prompt)
        try c.encodeIfPresent(firedAt, forKey: .firedAt)
        try c.encode(origin, forKey: .origin)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(createdBy, forKey: .createdBy)
        try c.encode(deliveryPolicy, forKey: .deliveryPolicy)
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
// (GeminiBackend was removed once Gemini moved to the headless `agy` CLI —
// there is only one Gemini drive path now, so no transport axis is needed.
// Old persisted sessions that carried geminiBackend/antigravityConversationId
// decode fine: those keys are simply ignored.)

public struct AgentSession: Codable, Hashable, Sendable, Identifiable {
    /// Server-assigned UUID. Used as `Identifiable.id` and as the URL
    /// segment in `/sessions/:id/*` endpoints.
    public let id: UUID
    /// The repo (canonical) the session is rooted in. **Optional in
    /// schema v5**: chat sessions (`kind == .chat`) leave this nil because
    /// they run in an empty chat-cwd, not in a git repo. Code sessions
    /// (`kind == .code`) always carry a non-nil repoKey. The spawn
    /// dispatcher pattern `session.worktreePath ?? session.repoKey` (~9
    /// call sites in AgentControlServer.swift) resolves to the chat-cwd
    /// for chat sessions because `worktreePath` is populated there.
    public let repoKey: String?
    /// Display label for the repo (denormalized for cheap list rendering).
    /// For chat sessions, set to a synthetic label like "Chat — {Provider}"
    /// at creation; `displayLabel` still prefers `customName` when set.
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
    /// Per-worktree creation/copy audit for Clawdmeter-owned isolated
    /// sessions. Nil for legacy, local, and externally-owned sessions.
    public let provisioning: WorktreeProvisioningMetadata?
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
    /// Last plan the user approved before the daemon respawned the runtime
    /// with write access. Kept separate from `planText` so approval can clear
    /// pending CTA state without losing the reviewable plan file.
    public let approvedPlanText: String?
    /// Daemon-computed progress against `approvedPlanText`. `nil` until the
    /// daemon's first recompute after approval, or whenever the plan has
    /// no extractable step markers. Optional + decoder-tolerant so older
    /// persisted sessions decode cleanly (same pattern as the schema v5/v6
    /// additions below).
    public let planProgress: PlanProgress?
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

    // MARK: - Code V2 schema v8 additions (wire v15)

    /// Durable workspace/worktree id. Nil for legacy sessions created
    /// before Code V2 workspace persistence landed.
    public let workspaceId: UUID?
    /// Explicit cwd for the runtime process. For code sessions this is the
    /// worktree root when isolated, otherwise the repo root. For chat
    /// sessions this is the per-chat cwd.
    public let runtimeCwd: String?
    /// Explicit chat cwd. Kept separate from `runtimeCwd` because a future
    /// editor bridge can attach chat context from one directory while the
    /// runtime executes inside an isolated worktree.
    public let chatCwd: String?
    /// Durable runtime/provider binding. Replaces implicit "AgentKind means
    /// transport + billing + external id" assumptions.
    public let runtimeBinding: SessionRuntimeBinding?
    /// Backend-owned PR/check mirror. Nil until a PR exists or the daemon
    /// has polled the branch.
    public let prMirrorState: PRMirrorState?

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
    /// Durable winner for the A/B-pair decision. Kept separate from
    /// `abPairDecidedAt` because retries may claim a different winner after
    /// the CAS lock is already set; callers must receive the stored winner.
    public let abPairWinnerSessionId: UUID?

    /// v0.5.4: user-supplied display name. When set, replaces
    /// `repoDisplayName` in the sidebar row + chat header so the session
    /// can be labeled by what it's actually working on rather than just
    /// the repo name. Empty / whitespace-only strings normalize to nil
    /// at the daemon's rename handler.
    public let customName: String?

    /// v6 (Track A): the Claude CLI session id parsed from the JSONL header
    /// (NOT `AgentSession.id`). Used for `claude --resume` after idle-teardown
    /// or daemon relaunch. nil until captured post-spawn; re-captured per turn
    /// because Claude rotates the id after some operations.
    public let claudeSessionId: String?

    // MARK: - Sessions v2 schema v5 additions (v0.8.0 Chat tab)
    //
    // All optional + decoder-tolerant so v3/v4 sessions.json files
    // decode cleanly. v0.8 introduces the Chat tab; chat sessions
    // (`kind == .chat`) use these fields, code sessions leave them nil.

    /// Top-level session category. Defaults to `.code` on v3/v4 decode for
    /// back-compat. Chat sessions (`.chat`) ride the same AgentSession
    /// shape but with `repoKey: nil` and `worktreePath` set to the
    /// chat-cwd absolute path.
    public let kind: SessionKind
    /// When this chat is one of three Frontier siblings, the shared group
    /// id. Nil for solo chats and all code sessions. Frontier UI ships in
    /// v0.9; daemon endpoints + WS channel ship in v0.8 for forward-compat.
    public let frontierGroupId: UUID?
    /// 0/1/2 child index within a Frontier group. Pinned at spawn.
    public let frontierChildIndex: Int?
    /// For `agent == .codex && kind == .chat`, which backend spawned this
    /// session. Pinned at spawn-time per RE1; `nil` for non-Codex / non-chat
    /// sessions. v0.9 forward-compat: a future flip of the global default
    /// (PairingSettings.defaultCodexChatBackend) does not migrate live
    /// sessions; this field captures the irreversible spawn-time choice.
    public let codexChatBackend: CodexChatBackend?
    /// Legacy Codex SDK chat thread id. Kept decode-compatible for older
    /// persisted chat sessions; new Codex sessions drive through app-server
    /// and leave this nil.
    public let codexChatThreadId: String?

    // MARK: - Schema v6 additions (v0.8.1 agy-migration, wire v10)
    //
    // (Removed: geminiBackend / antigravityConversationId / antigravityProjectId.
    // Gemini drives only via the headless `agy` CLI now; these agentapi-era
    // fields are gone. Old persisted sessions carrying them decode fine —
    // unknown JSON keys are ignored.)

    // MARK: - Schema v7 additions (v0.23 Chat V2)
    //
    // Persists the Deep Research toggle on the session record so respawn/
    // restore/retry preserves the flag. Without this the bool only lives
    // on the create-request and is lost as soon as the daemon writes the
    // session to disk — meaning a Deep Research chat that respawns after
    // a daemon restart silently downgrades to a regular send (Codex
    // bug-audit P1 #6).
    //
    // Optional + decoder-tolerant: any v0.8.x / v0.9 sessions.json files
    // decode cleanly with this as `false`.

    /// When true, this chat session was spawned with provider-specific
    /// Deep Research settings.
    /// Defaults to false on older sessions.
    public let deepResearch: Bool

    // MARK: - Schema v8 additions (F3-wire, wire v20)
    //
    // Optional + decoder-tolerant: any v7-era sessions.json decodes
    // cleanly with this as nil. Nil means "primary instance for this
    // kind" — the back-compat default that resolves to
    // `ProviderInstanceId.primary(kind: agent)`.

    /// `ProviderInstanceId.wireId` this session is pinned to (e.g.
    /// `"claude/__primary__"`, `"claude/personal"`, `"codex/work"`).
    /// `nil` for any session created before F3-wire — those resolve to
    /// the primary instance at lookup time. Pinned at spawn-time so
    /// respawn / restore / retry preserves the per-instance HOME /
    /// Keychain / env scrubbing posture.
    public let providerInstanceId: String?

    // MARK: - Schema v9 additions (v0.29 workspace session tabs, wire v22)

    /// Sibling code-session ids whose transcript digests were inserted
    /// into this session's first user turn. Nil/empty means no inherited
    /// context. Kept separate from `parentSessionId`: parent sessions are
    /// threaded children, while this field is one-shot starting context.
    public let inheritedContextSourceIds: [UUID]?

    /// True only when Clawdmeter created this session's `worktreePath` via
    /// `WorktreeManager.add` and may therefore remove it when the session is
    /// ended. Same-workspace tabs can run in a worktree without owning it.
    public let ownsWorktree: Bool

    /// Repo environment set pinned at session creation. This stores only
    /// the set identity; secret values stay in the platform secret store.
    public let envSetId: UUID?
    public let envSetName: String?

    /// v28: when set, the session routes through a user-configured custom
    /// provider (OpenAI/Anthropic-compatible endpoint). Pinned at spawn so
    /// respawn/revive/approve-plan keep the same billing rail.
    public let customProviderId: String?

    public init(
        id: UUID,
        repoKey: String?,
        repoDisplayName: String,
        agent: AgentKind,
        model: String?,
        goal: String?,
        worktreePath: String?,
        provisioning: WorktreeProvisioningMetadata? = nil,
        tmuxWindowId: String?,
        tmuxPaneId: String?,
        status: AgentSessionStatus,
        planText: String?,
        approvedPlanText: String? = nil,
        createdAt: Date,
        lastEventAt: Date,
        lastEventSeq: UInt64,
        mode: SessionMode = .local,
        archivedAt: Date? = nil,
        terminalPanes: [TerminalPaneRef] = [],
        scheduledFollowUps: [ScheduledFollowUp] = [],
        parentSessionId: UUID? = nil,
        workspaceId: UUID? = nil,
        runtimeCwd: String? = nil,
        chatCwd: String? = nil,
        runtimeBinding: SessionRuntimeBinding? = nil,
        prMirrorState: PRMirrorState? = nil,
        effort: ReasoningEffort? = nil,
        abPairSessionId: UUID? = nil,
        abPairDecidedAt: Date? = nil,
        abPairWinnerSessionId: UUID? = nil,
        customName: String? = nil,
        claudeSessionId: String? = nil,
        kind: SessionKind = .code,
        frontierGroupId: UUID? = nil,
        frontierChildIndex: Int? = nil,
        codexChatBackend: CodexChatBackend? = nil,
        codexChatThreadId: String? = nil,
        deepResearch: Bool = false,
        planProgress: PlanProgress? = nil,
        providerInstanceId: String? = nil,
        inheritedContextSourceIds: [UUID]? = nil,
        ownsWorktree: Bool = false,
        envSetId: UUID? = nil,
        envSetName: String? = nil,
        customProviderId: String? = nil
    ) {
        self.id = id
        self.repoKey = repoKey
        self.repoDisplayName = repoDisplayName
        self.agent = agent
        self.model = model
        self.goal = goal
        self.worktreePath = worktreePath
        self.provisioning = provisioning
        self.tmuxWindowId = tmuxWindowId
        self.tmuxPaneId = tmuxPaneId
        self.status = status
        self.planText = planText
        self.approvedPlanText = approvedPlanText
        self.createdAt = createdAt
        self.lastEventAt = lastEventAt
        self.lastEventSeq = lastEventSeq
        self.mode = mode
        self.archivedAt = archivedAt
        self.terminalPanes = terminalPanes
        self.scheduledFollowUps = scheduledFollowUps
        self.parentSessionId = parentSessionId
        self.workspaceId = workspaceId
        self.runtimeCwd = runtimeCwd
        self.chatCwd = chatCwd
        self.runtimeBinding = runtimeBinding
        self.prMirrorState = prMirrorState
        self.effort = effort
        self.abPairSessionId = abPairSessionId
        self.abPairDecidedAt = abPairDecidedAt
        self.abPairWinnerSessionId = abPairWinnerSessionId
        self.customName = customName
        self.claudeSessionId = claudeSessionId
        self.kind = kind
        self.frontierGroupId = frontierGroupId
        self.frontierChildIndex = frontierChildIndex
        self.codexChatBackend = codexChatBackend
        self.codexChatThreadId = codexChatThreadId
        self.deepResearch = deepResearch
        self.planProgress = planProgress
        self.providerInstanceId = providerInstanceId
        self.inheritedContextSourceIds = inheritedContextSourceIds
        self.ownsWorktree = ownsWorktree
        self.envSetId = envSetId
        self.envSetName = envSetName
        self.customProviderId = customProviderId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        // v5: repoKey is optional (chat sessions have nil). v3/v4 readers
        // wrote a non-nil String here; decodeIfPresent handles both.
        self.repoKey = try c.decodeIfPresent(String.self, forKey: .repoKey)
        self.repoDisplayName = try c.decode(String.self, forKey: .repoDisplayName)
        self.agent = try c.decode(AgentKind.self, forKey: .agent)
        self.model = try c.decodeIfPresent(String.self, forKey: .model)
        self.goal = try c.decodeIfPresent(String.self, forKey: .goal)
        self.worktreePath = try c.decodeIfPresent(String.self, forKey: .worktreePath)
        self.provisioning = (try? c.decodeIfPresent(WorktreeProvisioningMetadata.self, forKey: .provisioning)) ?? nil
        self.tmuxWindowId = try c.decodeIfPresent(String.self, forKey: .tmuxWindowId)
        self.tmuxPaneId = try c.decodeIfPresent(String.self, forKey: .tmuxPaneId)
        self.status = try c.decode(AgentSessionStatus.self, forKey: .status)
        self.planText = try c.decodeIfPresent(String.self, forKey: .planText)
        self.approvedPlanText = try c.decodeIfPresent(String.self, forKey: .approvedPlanText)
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
        // Code V2 schema v8 fields. All optional + decoder-tolerant so
        // pre-v15 sessions.json files survive unchanged.
        self.workspaceId = (try? c.decodeIfPresent(UUID.self, forKey: .workspaceId)) ?? nil
        self.runtimeCwd = (try? c.decodeIfPresent(String.self, forKey: .runtimeCwd)) ?? nil
        self.chatCwd = (try? c.decodeIfPresent(String.self, forKey: .chatCwd)) ?? nil
        self.runtimeBinding = (try? c.decodeIfPresent(SessionRuntimeBinding.self, forKey: .runtimeBinding)) ?? nil
        self.prMirrorState = (try? c.decodeIfPresent(PRMirrorState.self, forKey: .prMirrorState)) ?? nil
        // Schema v3 fields: optional + decoder-tolerant so v2 files decode.
        self.effort = (try? c.decodeIfPresent(ReasoningEffort.self, forKey: .effort)) ?? nil
        self.abPairSessionId = (try? c.decodeIfPresent(UUID.self, forKey: .abPairSessionId)) ?? nil
        self.abPairDecidedAt = (try? c.decodeIfPresent(Date.self, forKey: .abPairDecidedAt)) ?? nil
        self.abPairWinnerSessionId = (try? c.decodeIfPresent(UUID.self, forKey: .abPairWinnerSessionId)) ?? nil
        // v0.5.4 schema addition: customName. Optional + decoder-tolerant
        // so v3 sessions.json files decode cleanly (the field just stays
        // nil).
        self.customName = (try? c.decodeIfPresent(String.self, forKey: .customName)) ?? nil
        // v6 (Track A): claudeSessionId. decodeIfPresent → a v5 sessions.json
        // (no key) decodes cleanly to nil.
        self.claudeSessionId = (try? c.decodeIfPresent(String.self, forKey: .claudeSessionId)) ?? nil
        // v0.8.0 schema v5 additions: kind, frontierGroupId, frontierChildIndex,
        // codexChatBackend, codexChatThreadId. All optional + decoder-tolerant
        // so v3/v4 sessions.json files decode unchanged (defaults below).
        self.kind = (try? c.decodeIfPresent(SessionKind.self, forKey: .kind)) ?? .code
        self.frontierGroupId = (try? c.decodeIfPresent(UUID.self, forKey: .frontierGroupId)) ?? nil
        self.frontierChildIndex = (try? c.decodeIfPresent(Int.self, forKey: .frontierChildIndex)) ?? nil
        self.codexChatBackend = (try? c.decodeIfPresent(CodexChatBackend.self, forKey: .codexChatBackend)) ?? nil
        self.codexChatThreadId = (try? c.decodeIfPresent(String.self, forKey: .codexChatThreadId)) ?? nil
        // v0.23 schema v7 addition: deepResearch. Persisted so respawn/
        // restore/retry preserves the flag. Older sessions.json files
        // decode this as false.
        self.deepResearch = (try? c.decodeIfPresent(Bool.self, forKey: .deepResearch)) ?? false
        // Plan-progress schema addition: optional + decoder-tolerant so
        // every pre-existing sessions.json decodes cleanly with this nil.
        // The daemon populates it on the first SessionChatStore snapshot
        // after `approvedPlanText` is set.
        self.planProgress = (try? c.decodeIfPresent(PlanProgress.self, forKey: .planProgress)) ?? nil
        // F3-wire schema v8 addition (wire v20): providerInstanceId.
        // Optional + decoder-tolerant; any pre-F3-wire sessions.json
        // decodes with this nil, resolving at lookup time to
        // `ProviderInstanceId.primary(kind: agent)`.
        self.providerInstanceId = (try? c.decodeIfPresent(String.self, forKey: .providerInstanceId)) ?? nil
        // v0.29 schema v9 addition: workspace-tab inherited context.
        // Optional + decoder-tolerant so older sessions stay nil.
        self.inheritedContextSourceIds = (try? c.decodeIfPresent([UUID].self, forKey: .inheritedContextSourceIds)) ?? nil
        // v0.29 schema v9 addition: explicit worktree ownership. Missing
        // legacy values decode to false because destructive cleanup must be
        // opt-in once same-workspace tabs can share a worktree path.
        if let decodedOwnsWorktree = try? c.decodeIfPresent(Bool.self, forKey: .ownsWorktree) {
            self.ownsWorktree = decodedOwnsWorktree
        } else {
            self.ownsWorktree = false
        }
        self.envSetId = (try? c.decodeIfPresent(UUID.self, forKey: .envSetId)) ?? nil
        self.envSetName = (try? c.decodeIfPresent(String.self, forKey: .envSetName)) ?? nil
        self.customProviderId = (try? c.decodeIfPresent(String.self, forKey: .customProviderId)) ?? nil
    }

    /// User-facing label for the session. Prefers the user-set
    /// `customName` (when non-empty), otherwise falls back to
    /// `repoDisplayName` so existing sessions render identically.
    public var displayLabel: String {
        if let name = customName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return name
        }
        return repoDisplayName
    }

    /// The session's effective working directory — what every filesystem,
    /// git, tmux, and JSONL operation needs. For code sessions: the
    /// worktree if `useWorktree` was on at create, else the repo root.
    /// For chat sessions: the chat-cwd in `worktreePath` (always set
    /// at spawn). The daemon enforces the invariant that at least one
    /// of (worktreePath, repoKey) is non-nil at persistence time;
    /// preconditionFailure here catches any drift in that invariant.
    public var effectiveCwd: String {
        if let cwd = runtimeCwd, !cwd.isEmpty { return cwd }
        if kind == .chat, let cwd = chatCwd, !cwd.isEmpty { return cwd }
        if let wt = worktreePath, !wt.isEmpty { return wt }
        if let rk = repoKey, !rk.isEmpty { return rk }
        preconditionFailure("AgentSession \(id) has no runtimeCwd/chatCwd/worktreePath/repoKey — daemon spawned an invalid session (kind=\(kind))")
    }

    private enum CodingKeys: String, CodingKey {
        case id, repoKey, repoDisplayName, agent, model, goal,
             worktreePath, provisioning, tmuxWindowId, tmuxPaneId,
             status, planText, approvedPlanText, createdAt, lastEventAt, lastEventSeq,
             mode, archivedAt,
             terminalPanes, scheduledFollowUps, parentSessionId,
             // v15 Code V2 control-plane fields.
             workspaceId, runtimeCwd, chatCwd, runtimeBinding, prMirrorState,
             effort, abPairSessionId, abPairDecidedAt, abPairWinnerSessionId,
             customName,
             // v0.8.0 schema v5 (Chat tab).
             kind, frontierGroupId, frontierChildIndex,
             codexChatBackend, codexChatThreadId,
             // v0.23 schema v7 (Chat V2 Deep Research).
             deepResearch,
             // Plan-progress schema addition (daemon-side).
             planProgress,
             // F3-wire schema v8 (configured-instance pin).
             providerInstanceId,
             // v0.29 schema v9 (workspace session tabs).
             inheritedContextSourceIds,
             ownsWorktree,
             // Repo env sets.
             envSetId, envSetName,
             // v28 custom provider routing pin.
             customProviderId,
             // v6 (Track A): Claude PTY CLI session id.
             claudeSessionId
    }

    /// Resolve `providerInstanceId` (a `ProviderInstanceId.wireId` string)
    /// against the daemon's `ProviderInstanceRegistry`. Returns the
    /// registered instance when found, else falls back to
    /// `ProviderInstanceId.primary(kind: agent)` (the back-compat default).
    ///
    /// F3-wire (Codex eng-review #10): every spawn / token / log call
    /// site that needs the configured instance for this session funnels
    /// through here so the back-compat path is a single line.
    public func resolveProviderInstance(in registry: ProviderInstanceRegistry) async -> ProviderInstanceId {
        if let wireId = providerInstanceId,
           let instance = await registry.lookup(wireId: wireId) {
            return instance
        }
        return ProviderInstanceId.primary(kind: agent)
    }
}

// MARK: - Rename request

/// `POST /sessions/:id/rename` body. The daemon normalizes empty/
/// whitespace-only strings to `nil` (clearing the custom name) before
/// persisting.
public struct RenameSessionRequest: Codable, Sendable {
    public let name: String?

    public init(name: String?) {
        self.name = name
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
    /// and the agent's cwd becomes the worktree path. v0.7.9: defaulted
    /// to `true` everywhere — every new session lands in a city-named
    /// worktree + branch (see `WorktreeManager.slug(city:)`).
    public let useWorktree: Bool
    /// Base branch for the worktree. `nil` defaults to the repo's HEAD.
    public let baseBranch: String?
    /// Per-session reasoning effort. `nil` = CLI default. Sessions v2 D3.
    public let effort: ReasoningEffort?
    /// If non-nil, spawn this session AND a sibling using `abPair` as the
    /// second agent (the same goal/model/effort, in a sibling worktree).
    /// Phase 7 dmux feature.
    public let abPair: AgentKind?

    /// Configured provider instance to pin this session to (F3-wire,
    /// wire v20). `nil` resolves to `ProviderInstanceId.primary(kind:)`
    /// — the back-compat default — so clients on `wireVersion <
    /// providerInstanceMinimum` continue to land on the single-instance
    /// daemon path without modification. Format: `ProviderInstanceId.wireId`,
    /// e.g. `"claude/__primary__"`, `"claude/personal"`, `"codex/work"`.
    ///
    /// Daemon contract: when set, the daemon spawns the child process
    /// with `HOME=<instance.homePathOverride ?? userHome>` and scrubs
    /// any inherited provider-namespaced env vars (`CLAUDE_*`, `CODEX_*`,
    /// …) so credentials from a sibling instance can't leak into this
    /// spawn. See `ProviderInstanceEnvironment.buildEnv(for:)`.
    public let providerInstanceId: String?

    /// Code-tab harness migration (wire `harnessSpawnMinimum`): when the Mac
    /// client has already provisioned the git worktree locally (to drive the
    /// optimistic "+" provisioning trail), it passes the resolved cwd here so
    /// the daemon's harness spawn reuses it instead of provisioning a second
    /// worktree. `nil` = daemon provisions (back-compat / iOS path).
    public let existingWorkspacePath: String?

    /// Code-tab harness migration: pre-minted session id so the optimistic
    /// provisional `AgentSession` the Mac created up front and the daemon's
    /// harness session are the SAME row (open-state / draft / trail key off
    /// this id). `nil` = daemon mints a fresh id (back-compat / iOS path).
    public let sessionId: UUID?

    /// v28: route spawn through a user-configured custom provider.
    public let customProviderId: String?

    public init(
        repoKey: String,
        agent: AgentKind,
        model: String? = nil,
        planMode: Bool = false,
        goal: String? = nil,
        useWorktree: Bool = true,
        baseBranch: String? = nil,
        effort: ReasoningEffort? = nil,
        abPair: AgentKind? = nil,
        providerInstanceId: String? = nil,
        existingWorkspacePath: String? = nil,
        sessionId: UUID? = nil,
        customProviderId: String? = nil
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
        self.providerInstanceId = providerInstanceId
        self.existingWorkspacePath = existingWorkspacePath
        self.sessionId = sessionId
        self.customProviderId = customProviderId
    }

    // Custom decoder to tolerate v2 requests missing the new fields.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.repoKey = try c.decode(String.self, forKey: .repoKey)
        self.agent = try c.decode(AgentKind.self, forKey: .agent)
        self.model = try c.decodeIfPresent(String.self, forKey: .model)
        self.planMode = (try? c.decode(Bool.self, forKey: .planMode)) ?? false
        self.goal = try c.decodeIfPresent(String.self, forKey: .goal)
        // v0.7.9: default flipped to true. Older v6/v7 clients that
        // omit the field now opt into worktrees automatically — same
        // behaviour as the v0.7.9+ UI which has no explicit mode chip.
        self.useWorktree = (try? c.decode(Bool.self, forKey: .useWorktree)) ?? true
        self.baseBranch = try c.decodeIfPresent(String.self, forKey: .baseBranch)
        self.effort = try c.decodeIfPresent(ReasoningEffort.self, forKey: .effort)
        self.abPair = try c.decodeIfPresent(AgentKind.self, forKey: .abPair)
        // F3-wire (v20). decodeIfPresent so v19 clients omitting the
        // field deserialize cleanly — the server treats nil as
        // "primary instance for this kind".
        self.providerInstanceId = try c.decodeIfPresent(String.self, forKey: .providerInstanceId)
        // v27 Code-tab harness migration. decodeIfPresent so v26 daemons/
        // clients omitting the fields deserialize cleanly (back-compat).
        self.existingWorkspacePath = try c.decodeIfPresent(String.self, forKey: .existingWorkspacePath)
        self.sessionId = try c.decodeIfPresent(UUID.self, forKey: .sessionId)
        self.customProviderId = try c.decodeIfPresent(String.self, forKey: .customProviderId)
    }

    private enum CodingKeys: String, CodingKey {
        case repoKey, agent, model, planMode, goal, useWorktree, baseBranch, effort, abPair, providerInstanceId
        case existingWorkspacePath, sessionId, customProviderId
    }
}

// MARK: - Mid-session change requests (Sessions v2 Phase 0)

/// `POST /sessions/:id/model` body. Mid-session model swap.
public struct ChangeModelRequest: Codable, Sendable {
    public let model: String
    /// Optional new effort to apply together with the model swap. If nil,
    /// existing effort is preserved.
    public let effort: ReasoningEffort?
    /// Code V2 mobile outbox dedupe key. v16+ servers reuse the receipt
    /// for replays of the same key.
    public let idempotencyKey: String?
    /// v28: collision-safe model lookup scope for custom providers.
    public let customProviderId: String?

    public init(
        model: String,
        effort: ReasoningEffort? = nil,
        idempotencyKey: String? = nil,
        customProviderId: String? = nil
    ) {
        self.model = model
        self.effort = effort
        self.idempotencyKey = idempotencyKey
        self.customProviderId = customProviderId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.model = try c.decode(String.self, forKey: .model)
        self.effort = try c.decodeIfPresent(ReasoningEffort.self, forKey: .effort)
        self.idempotencyKey = try c.decodeIfPresent(String.self, forKey: .idempotencyKey)
        self.customProviderId = try c.decodeIfPresent(String.self, forKey: .customProviderId)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(model, forKey: .model)
        try c.encodeIfPresent(effort, forKey: .effort)
        try c.encodeIfPresent(idempotencyKey, forKey: .idempotencyKey)
        try c.encodeIfPresent(customProviderId, forKey: .customProviderId)
    }

    private enum CodingKeys: String, CodingKey {
        case model, effort, idempotencyKey, customProviderId
    }
}

/// `POST /sessions/:id/mode` body. Mid-session mode change (local/worktree;
/// `.cloud` rejected with 400). Optional plan-mode flip alongside.
public struct ChangeModeRequest: Codable, Sendable {
    public let mode: SessionMode
    /// Claude-only. Ignored for Codex.
    public let planMode: Bool?
    public let idempotencyKey: String?

    public init(mode: SessionMode, planMode: Bool? = nil, idempotencyKey: String? = nil) {
        self.mode = mode
        self.planMode = planMode
        self.idempotencyKey = idempotencyKey
    }
}

/// `POST /sessions/:id/effort` body. Effort-only swap (cheaper than model
/// swap; still triggers respawn).
public struct ChangeEffortRequest: Codable, Sendable {
    public let effort: ReasoningEffort
    public let idempotencyKey: String?

    public init(effort: ReasoningEffort, idempotencyKey: String? = nil) {
        self.effort = effort
        self.idempotencyKey = idempotencyKey
    }
}

/// `POST /sessions/:id/send` body. Inject a prompt into the running agent's
/// tmux pane. >256 bytes uses paste-buffer; otherwise send-keys.
public struct SendPromptRequest: Codable, Sendable {
    public let text: String
    /// If true, the daemon writes to tmux paste-buffer + pastes (good for
    /// multi-line / IME / large content). If false, plain send-keys.
    public let asFollowUp: Bool
    /// Code V2 mobile outbox dedupe key. Optional for legacy clients;
    /// durable mobile sends should populate it.
    public let idempotencyKey: String?
    /// Who is asking to spend a provider turn. Missing values decode as
    /// `legacyClient`; provider writes fail closed for that origin unless a
    /// current UI path restamps the request as user-authored.
    public let origin: ProviderPromptOrigin
    public let clientIntentId: String?

    public init(
        text: String,
        asFollowUp: Bool = true,
        idempotencyKey: String? = nil,
        origin: ProviderPromptOrigin = .legacyClient,
        clientIntentId: String? = nil
    ) {
        self.text = text
        self.asFollowUp = asFollowUp
        self.idempotencyKey = idempotencyKey
        self.origin = origin
        self.clientIntentId = clientIntentId
    }

    private enum CodingKeys: String, CodingKey {
        case text, asFollowUp, idempotencyKey, origin, clientIntentId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        asFollowUp = try c.decodeIfPresent(Bool.self, forKey: .asFollowUp) ?? true
        idempotencyKey = try c.decodeIfPresent(String.self, forKey: .idempotencyKey)
        origin = try c.decodeIfPresent(ProviderPromptOrigin.self, forKey: .origin) ?? .legacyClient
        clientIntentId = try c.decodeIfPresent(String.self, forKey: .clientIntentId)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(text, forKey: .text)
        try c.encode(asFollowUp, forKey: .asFollowUp)
        try c.encodeIfPresent(idempotencyKey, forKey: .idempotencyKey)
        try c.encode(origin, forKey: .origin)
        try c.encodeIfPresent(clientIntentId, forKey: .clientIntentId)
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
    public let idempotencyKey: String?

    public init(enabled: Bool, idempotencyKey: String? = nil) {
        self.enabled = enabled
        self.idempotencyKey = idempotencyKey
    }
}

/// `POST /providers/:id/auto-revive` body. D4 (v0.17, wire v12). iOS
/// Live tab fans the per-provider auto-revive toggle through here; the
/// Mac daemon dispatches to the matching AppModel.setAutoReviveEnabled.
public struct SetAutoReviveRequest: Codable, Sendable {
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
    public let idempotencyKey: String?

    public init(winnerSessionId: UUID, idempotencyKey: String? = nil) {
        self.winnerSessionId = winnerSessionId
        self.idempotencyKey = idempotencyKey
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

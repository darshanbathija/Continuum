import Foundation

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
    /// v0.7.8: Codex SDK `todo_list` events surface here so the iOS
    /// Plan tab + Watch complication can render structured todos.
    /// Empty for non-Codex sessions and for Codex sessions that
    /// haven't received a todo_list event yet.
    public let codexTodos: [CodexTodoItem]
    /// v0.8 QA: a CLI permission prompt that needs user input —
    /// e.g. Codex's "Do you trust this directory?", Claude's per-tool
    /// approval requests. The Mac/iOS chat UI renders this as an
    /// AskUserQuestion-style card with option buttons; selecting one
    /// POSTs to `/sessions/:id/permission-respond` and the daemon
    /// dispatches the appropriate keys to the CLI's TUI. Nil when no
    /// prompt is pending.
    public let pendingPermissionPrompt: PendingPermissionPrompt?
    public let totalInputTokens: Int
    public let totalOutputTokens: Int
    public let cacheReadTokens: Int
    public let cacheCreationTokens: Int
    public let lastEventAt: Date?
    public let updateCounter: UInt64
    /// v14 (Chat V2): explicit lifecycle state for the most-recent turn.
    /// Drives the V2 status strip (stopwatch clamp, Stop↔Send transition,
    /// indicator ring pause). `.idle` is the decode-default so older Macs
    /// (wire ≤ v13) round-trip without crashing; V2 clients fall back to
    /// a 2-second heartbeat heuristic when the paired Mac is too old.
    public let currentTurnState: TurnState

    public init(
        sessionId: UUID,
        items: [ChatItem],
        planSteps: [PlanStep],
        sourceEntries: [SourceEntry],
        artifactEntries: [ArtifactEntry],
        codexTodos: [CodexTodoItem] = [],
        pendingPermissionPrompt: PendingPermissionPrompt? = nil,
        totalInputTokens: Int,
        totalOutputTokens: Int,
        cacheReadTokens: Int = 0,
        cacheCreationTokens: Int = 0,
        lastEventAt: Date?,
        updateCounter: UInt64,
        currentTurnState: TurnState = .idle
    ) {
        self.sessionId = sessionId
        self.items = items
        self.planSteps = planSteps
        self.sourceEntries = sourceEntries
        self.artifactEntries = artifactEntries
        self.codexTodos = codexTodos
        self.pendingPermissionPrompt = pendingPermissionPrompt
        self.totalInputTokens = totalInputTokens
        self.totalOutputTokens = totalOutputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.lastEventAt = lastEventAt
        self.updateCounter = updateCounter
        self.currentTurnState = currentTurnState
    }

    // v0.7.8: custom decoder so older paired Macs (pre-codexTodos)
    // still produce a valid struct — missing field defaults to empty.
    private enum CodingKeys: String, CodingKey {
        case sessionId, items, planSteps, sourceEntries, artifactEntries
        case codexTodos
        case pendingPermissionPrompt
        case totalInputTokens, totalOutputTokens, cacheReadTokens, cacheCreationTokens
        case lastEventAt, updateCounter
        case currentTurnState
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.sessionId = try c.decode(UUID.self, forKey: .sessionId)
        self.items = try c.decode([ChatItem].self, forKey: .items)
        self.planSteps = try c.decode([PlanStep].self, forKey: .planSteps)
        self.sourceEntries = try c.decode([SourceEntry].self, forKey: .sourceEntries)
        self.artifactEntries = try c.decode([ArtifactEntry].self, forKey: .artifactEntries)
        self.codexTodos = try c.decodeIfPresent([CodexTodoItem].self, forKey: .codexTodos) ?? []
        self.pendingPermissionPrompt = try c.decodeIfPresent(PendingPermissionPrompt.self, forKey: .pendingPermissionPrompt)
        self.totalInputTokens = try c.decode(Int.self, forKey: .totalInputTokens)
        self.totalOutputTokens = try c.decode(Int.self, forKey: .totalOutputTokens)
        self.cacheReadTokens = try c.decodeIfPresent(Int.self, forKey: .cacheReadTokens) ?? 0
        self.cacheCreationTokens = try c.decodeIfPresent(Int.self, forKey: .cacheCreationTokens) ?? 0
        self.lastEventAt = try c.decodeIfPresent(Date.self, forKey: .lastEventAt)
        self.updateCounter = try c.decode(UInt64.self, forKey: .updateCounter)
        self.currentTurnState = try c.decodeIfPresent(TurnState.self, forKey: .currentTurnState) ?? .idle
    }
}

// MARK: - Chat shell/detail split (A10 — wireVersion 21)

/// Lightweight "shell" event emitted on every chat-subscribe commit when the
/// paired client speaks `wireVersion >= 21`. Contains only the bare header
/// needed to drive the activity strip / sidebar summary without waiting for
/// the heavy body:
///
///   - `sessionId` + `sequenceNumber` reference the paired `ChatDetailEvent`
///     so consumers can stitch the two frames back together.
///   - `kind` is the most-recent activity bucket (assistant streaming, user
///     prompt, tool call, system). Drives the small subtitle "Assistant
///     typing…" / "Tool running…" without rendering the full text.
///   - `emittedAt` is the snapshot's `lastEventAt` (server-time of the most
///     recent ingested event).
///   - `tokensIn` / `tokensOut` carry running totals so the activity-strip
///     counter can update before the heavy detail lands. Both are present
///     only when there's been an assistant turn this snapshot.
///   - `turnState` mirrors `WireChatSnapshot.currentTurnState` so the Stop↔
///     Send transition + stopwatch can flip immediately on shell.
///
/// **Wire payload:** ~80 bytes JSON typical. The matching `ChatDetailEvent`
/// carries the rest. v20 and earlier clients never see this type — they
/// keep receiving full `WireChatSnapshot` frames. The dispatch decision is
/// made ONCE at subscribe time from the client's reported `wireVersion`.
public struct ChatShellEvent: Codable, Sendable, Hashable {
    public let sessionId: UUID
    /// Monotonic per-session counter that pairs this shell event with its
    /// matching `ChatDetailEvent`. Same value as the underlying
    /// `WireChatSnapshot.updateCounter` so consumers can `removeDuplicates`
    /// and stitch shell↔detail without a separate id field.
    public let sequenceNumber: UInt64
    /// Most-recent activity bucket for the activity strip subtitle.
    public let kind: Kind
    /// Snapshot's `lastEventAt` — server-time of the most recent ingested
    /// chat event. Drives the "x min ago" relative-time label.
    public let emittedAt: Date?
    /// Running input-token total for the session. Optional because non-chat
    /// sessions and brand-new sessions don't have one yet.
    public let tokensIn: Int?
    /// Running output-token total for the session.
    public let tokensOut: Int?
    /// Per-turn lifecycle so the V2 status strip's Stop↔Send flip can land
    /// on the shell event without waiting for the heavy detail.
    public let turnState: TurnState

    /// Coarse-grained activity bucket. The sidebar / activity strip uses
    /// this to render the subtitle without parsing the full message body.
    public enum Kind: String, Codable, Sendable, Hashable, CaseIterable {
        /// Empty session / nothing rendered yet.
        case empty
        /// User-prompt message is the most-recent item.
        case user
        /// Assistant-prose message is the most-recent item (or streaming
        /// in-flight).
        case assistant
        /// Tool call is the most-recent item.
        case tool
        /// Meta / system message (e.g. permission prompt, summary).
        case system

        /// Lenient decoder so a future wireVersion that adds a new kind
        /// doesn't crash older v21 clients. Unknown raws fall back to
        /// `.system` (safe default — UI keeps showing the indicator).
        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            let raw = try c.decode(String.self)
            self = Kind(rawValue: raw) ?? .system
        }
    }

    public init(
        sessionId: UUID,
        sequenceNumber: UInt64,
        kind: Kind,
        emittedAt: Date?,
        tokensIn: Int? = nil,
        tokensOut: Int? = nil,
        turnState: TurnState = .idle
    ) {
        self.sessionId = sessionId
        self.sequenceNumber = sequenceNumber
        self.kind = kind
        self.emittedAt = emittedAt
        self.tokensIn = tokensIn
        self.tokensOut = tokensOut
        self.turnState = turnState
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, sequenceNumber, kind, emittedAt
        case tokensIn, tokensOut, turnState
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.sessionId = try c.decode(UUID.self, forKey: .sessionId)
        self.sequenceNumber = try c.decode(UInt64.self, forKey: .sequenceNumber)
        self.kind = try c.decode(Kind.self, forKey: .kind)
        self.emittedAt = try c.decodeIfPresent(Date.self, forKey: .emittedAt)
        self.tokensIn = try c.decodeIfPresent(Int.self, forKey: .tokensIn)
        self.tokensOut = try c.decodeIfPresent(Int.self, forKey: .tokensOut)
        self.turnState = try c.decodeIfPresent(TurnState.self, forKey: .turnState) ?? .idle
    }

    /// Derive the activity-strip Kind from the most-recent chat item. The
    /// daemon uses this when constructing a shell event from a snapshot.
    public static func kind(from items: [ChatItem]) -> Kind {
        guard let last = items.last else { return .empty }
        switch last {
        case .message(let m):
            switch m.kind {
            case .userText:      return .user
            case .assistantText: return .assistant
            case .toolCall, .toolResult: return .tool
            case .meta:          return .system
            }
        case .toolRun:
            return .tool
        }
    }
}

/// Heavy "detail" event paired with a `ChatShellEvent`. Carries the full
/// chat body: items (messages + tool runs), plan steps, source entries,
/// artifacts, codex todos, token breakdowns, and the pending permission
/// prompt. Sent as the second frame on each commit when the paired client
/// speaks `wireVersion >= 21`.
///
/// `sessionId` + `sequenceNumber` match the immediately-preceding shell
/// event so consumers can pair them. v20 and earlier clients never see
/// this type — they keep receiving full `WireChatSnapshot` frames.
public struct ChatDetailEvent: Codable, Sendable, Hashable {
    public let sessionId: UUID
    /// Matches the paired `ChatShellEvent.sequenceNumber` AND the
    /// underlying `WireChatSnapshot.updateCounter`. Lets the iOS store
    /// stitch the two frames together (or drop a stale detail if the
    /// shell counter has already advanced past it).
    public let sequenceNumber: UInt64
    public let items: [ChatItem]
    public let planSteps: [PlanStep]
    public let sourceEntries: [SourceEntry]
    public let artifactEntries: [ArtifactEntry]
    public let codexTodos: [CodexTodoItem]
    public let pendingPermissionPrompt: PendingPermissionPrompt?
    public let totalInputTokens: Int
    public let totalOutputTokens: Int
    public let cacheReadTokens: Int
    public let cacheCreationTokens: Int

    public init(
        sessionId: UUID,
        sequenceNumber: UInt64,
        items: [ChatItem],
        planSteps: [PlanStep],
        sourceEntries: [SourceEntry],
        artifactEntries: [ArtifactEntry],
        codexTodos: [CodexTodoItem] = [],
        pendingPermissionPrompt: PendingPermissionPrompt? = nil,
        totalInputTokens: Int,
        totalOutputTokens: Int,
        cacheReadTokens: Int = 0,
        cacheCreationTokens: Int = 0
    ) {
        self.sessionId = sessionId
        self.sequenceNumber = sequenceNumber
        self.items = items
        self.planSteps = planSteps
        self.sourceEntries = sourceEntries
        self.artifactEntries = artifactEntries
        self.codexTodos = codexTodos
        self.pendingPermissionPrompt = pendingPermissionPrompt
        self.totalInputTokens = totalInputTokens
        self.totalOutputTokens = totalOutputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, sequenceNumber
        case items, planSteps, sourceEntries, artifactEntries
        case codexTodos, pendingPermissionPrompt
        case totalInputTokens, totalOutputTokens
        case cacheReadTokens, cacheCreationTokens
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.sessionId = try c.decode(UUID.self, forKey: .sessionId)
        self.sequenceNumber = try c.decode(UInt64.self, forKey: .sequenceNumber)
        self.items = try c.decode([ChatItem].self, forKey: .items)
        self.planSteps = try c.decode([PlanStep].self, forKey: .planSteps)
        self.sourceEntries = try c.decode([SourceEntry].self, forKey: .sourceEntries)
        self.artifactEntries = try c.decode([ArtifactEntry].self, forKey: .artifactEntries)
        self.codexTodos = try c.decodeIfPresent([CodexTodoItem].self, forKey: .codexTodos) ?? []
        self.pendingPermissionPrompt = try c.decodeIfPresent(PendingPermissionPrompt.self, forKey: .pendingPermissionPrompt)
        self.totalInputTokens = try c.decode(Int.self, forKey: .totalInputTokens)
        self.totalOutputTokens = try c.decode(Int.self, forKey: .totalOutputTokens)
        self.cacheReadTokens = try c.decodeIfPresent(Int.self, forKey: .cacheReadTokens) ?? 0
        self.cacheCreationTokens = try c.decodeIfPresent(Int.self, forKey: .cacheCreationTokens) ?? 0
    }
}

/// Discriminated envelope for chat-subscribe WS frames. v21+ pushes
/// `.shell(...)` then `.detail(...)`; v20 and earlier push `.snapshot(...)`.
/// Each variant carries a `type` tag in JSON so the consumer can decode by
/// kind in one pass.
///
/// Wire JSON shape (all variants share the same envelope key):
///   ```
///   { "type": "shell",    "shell": {...} }
///   { "type": "detail",   "detail": {...} }
///   { "type": "snapshot", "snapshot": {...} }
///   ```
///
/// **Back-compat note:** v20 and earlier clients are NOT aware of this
/// envelope — the daemon sends them a raw `WireChatSnapshot` frame (no
/// envelope wrap). The envelope is only used on the v21+ path. This
/// preserves the legacy wire on the slow rollout window.
public enum ChatStreamFrame: Sendable, Hashable {
    case shell(ChatShellEvent)
    case detail(ChatDetailEvent)
    /// Legacy single-frame snapshot. Used by v21+ debugging / one-shot
    /// fixtures that want to round-trip the envelope; the live v20 path
    /// does NOT wrap snapshots in this envelope.
    case snapshot(WireChatSnapshot)

    /// Stable tag value for the envelope's `type` field. Decoders use
    /// this to dispatch the right inner type.
    public var typeTag: String {
        switch self {
        case .shell:    return "shell"
        case .detail:   return "detail"
        case .snapshot: return "snapshot"
        }
    }
}

extension ChatStreamFrame: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case shell, detail, snapshot
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "shell":
            self = .shell(try c.decode(ChatShellEvent.self, forKey: .shell))
        case "detail":
            self = .detail(try c.decode(ChatDetailEvent.self, forKey: .detail))
        case "snapshot":
            self = .snapshot(try c.decode(WireChatSnapshot.self, forKey: .snapshot))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c,
                debugDescription: "Unknown ChatStreamFrame type: \(type)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(typeTag, forKey: .type)
        switch self {
        case .shell(let e):    try c.encode(e, forKey: .shell)
        case .detail(let e):   try c.encode(e, forKey: .detail)
        case .snapshot(let s): try c.encode(s, forKey: .snapshot)
        }
    }
}

extension WireChatSnapshot {
    /// Derive a `ChatShellEvent` from this snapshot. Used by the daemon's
    /// `ChatStreamWebSocketChannel` when the paired client speaks v21+.
    public func shellEvent() -> ChatShellEvent {
        let tokensIn: Int? = totalInputTokens > 0 ? totalInputTokens : nil
        let tokensOut: Int? = totalOutputTokens > 0 ? totalOutputTokens : nil
        return ChatShellEvent(
            sessionId: sessionId,
            sequenceNumber: updateCounter,
            kind: ChatShellEvent.kind(from: items),
            emittedAt: lastEventAt,
            tokensIn: tokensIn,
            tokensOut: tokensOut,
            turnState: currentTurnState
        )
    }

    /// Derive a `ChatDetailEvent` from this snapshot. Used by the daemon's
    /// `ChatStreamWebSocketChannel` when the paired client speaks v21+.
    public func detailEvent() -> ChatDetailEvent {
        ChatDetailEvent(
            sessionId: sessionId,
            sequenceNumber: updateCounter,
            items: items,
            planSteps: planSteps,
            sourceEntries: sourceEntries,
            artifactEntries: artifactEntries,
            codexTodos: codexTodos,
            pendingPermissionPrompt: pendingPermissionPrompt,
            totalInputTokens: totalInputTokens,
            totalOutputTokens: totalOutputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheCreationTokens: cacheCreationTokens
        )
    }

    /// Combine a paired shell + detail event back into a `WireChatSnapshot`.
    /// Used by v21+ iOS clients to materialize the legacy snapshot from
    /// the split events for code paths that still consume the unified
    /// shape (e.g. `iOSChatStore.snapshot`).
    ///
    /// The shell + detail are expected to share the same `sequenceNumber`.
    /// When they don't (e.g. an out-of-order frame from a flaky network),
    /// consumers should drop the older frame and wait for a fresh pair —
    /// this method does NOT enforce the pairing; callers do.
    public static func combine(
        shell: ChatShellEvent,
        detail: ChatDetailEvent
    ) -> WireChatSnapshot {
        WireChatSnapshot(
            sessionId: shell.sessionId,
            items: detail.items,
            planSteps: detail.planSteps,
            sourceEntries: detail.sourceEntries,
            artifactEntries: detail.artifactEntries,
            codexTodos: detail.codexTodos,
            pendingPermissionPrompt: detail.pendingPermissionPrompt,
            totalInputTokens: detail.totalInputTokens,
            totalOutputTokens: detail.totalOutputTokens,
            cacheReadTokens: detail.cacheReadTokens,
            cacheCreationTokens: detail.cacheCreationTokens,
            lastEventAt: shell.emittedAt,
            updateCounter: shell.sequenceNumber,
            currentTurnState: shell.turnState
        )
    }
}

/// v0.8 QA: a CLI-side permission prompt surfaced to the user. The card
/// renders the title + detail and one button per option; the recommended
/// option is highlighted. Identifies are scoped per-session — the same
/// physical CLI prompt re-detected in the pane gets the same id so the
/// UI doesn't double-render.
public struct PendingPermissionPrompt: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    /// One-line question shown as the card title (e.g. "Trust this directory?").
    public let title: String
    /// Optional longer body (e.g. the chat-cwd path or the tool that's
    /// being requested). Nil for prompts where the title is sufficient.
    public let detail: String?
    /// Short chip label shown above the title — matches the
    /// AskUserQuestion "header" field (e.g. "Codex trust", "Claude tool").
    public let header: String
    public let options: [PermissionOption]
    public let surfacedAt: Date

    public init(
        id: String,
        title: String,
        detail: String? = nil,
        header: String,
        options: [PermissionOption],
        surfacedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.header = header
        self.options = options
        self.surfacedAt = surfacedAt
    }
}

public struct PermissionOption: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let label: String
    public let description: String?
    public let isRecommended: Bool
    public let isDestructive: Bool

    public init(
        id: String,
        label: String,
        description: String? = nil,
        isRecommended: Bool = false,
        isDestructive: Bool = false
    ) {
        self.id = id
        self.label = label
        self.description = description
        self.isRecommended = isRecommended
        self.isDestructive = isDestructive
    }
}

/// Request body for `POST /sessions/:id/permission-respond`. The daemon
/// looks up the pending prompt for the session, validates that
/// `promptId` matches (rejects stale clicks if the prompt was already
/// answered), maps `optionId` to the CLI-specific key sequence, sends
/// it through the session transport, and clears the pending prompt on
/// the session's store.
public struct PermissionRespondRequest: Codable, Sendable {
    public let promptId: String
    public let optionId: String
    public let idempotencyKey: String?

    public init(promptId: String, optionId: String, idempotencyKey: String? = nil) {
        self.promptId = promptId
        self.optionId = optionId
        self.idempotencyKey = idempotencyKey
    }
}

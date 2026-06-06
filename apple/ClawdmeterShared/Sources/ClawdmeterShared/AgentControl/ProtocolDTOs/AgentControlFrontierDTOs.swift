import Foundation

// MARK: - Chat tab (v0.8 — wire v9)

/// `POST /chat-sessions` request body. Spawns a new chat session
/// (`AgentSession.kind == .chat`) with an empty per-session chat-cwd.
/// `effort` is optional and only honored by providers that support it.
/// `codexChatBackend` is legacy/decode-compatible; new Codex sessions ignore
/// it and drive through app-server.
public struct CreateChatSessionRequest: Codable, Sendable {
    public let provider: AgentKind
    public let model: String?
    public let effort: ReasoningEffort?
    public let codexChatBackend: CodexChatBackend?
    public let chatVendor: ChatVendor?
    public let billingProvider: String?
    /// v14 (Chat V2): when true, the daemon spawns the chat with deep-
    /// research argv (Claude: `--allowedTools WebSearch,WebFetch,...` +
    /// `--append-system-prompt deep-research-prompt.txt` + `--effort max`).
    /// For managed chat providers, the route maps this to the provider's
    /// current deep-research settings. Defaults to false on older clients
    /// (decodeIfPresent).
    public let deepResearch: Bool

    public init(
        provider: AgentKind,
        model: String? = nil,
        effort: ReasoningEffort? = nil,
        codexChatBackend: CodexChatBackend? = nil,
        chatVendor: ChatVendor? = nil,
        billingProvider: String? = nil,
        deepResearch: Bool = false
    ) {
        self.provider = provider
        self.model = model
        self.effort = effort
        self.codexChatBackend = codexChatBackend
        self.chatVendor = chatVendor
        self.billingProvider = billingProvider
        self.deepResearch = deepResearch
    }

    private enum CodingKeys: String, CodingKey {
        case provider, model, effort, codexChatBackend, chatVendor, billingProvider, deepResearch
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.provider = try c.decode(AgentKind.self, forKey: .provider)
        self.model = try c.decodeIfPresent(String.self, forKey: .model)
        self.effort = try c.decodeIfPresent(ReasoningEffort.self, forKey: .effort)
        self.codexChatBackend = try c.decodeIfPresent(CodexChatBackend.self, forKey: .codexChatBackend)
        // Lenient: an unknown vendor rawValue (a newer client's vendor) decodes
        // to nil instead of failing the whole session decode. Forward-compat —
        // mirrors the wire's decodeIfPresent philosophy.
        self.chatVendor = (try? c.decodeIfPresent(ChatVendor.self, forKey: .chatVendor)) ?? nil
        self.billingProvider = try c.decodeIfPresent(String.self, forKey: .billingProvider)
        self.deepResearch = try c.decodeIfPresent(Bool.self, forKey: .deepResearch) ?? false
    }
}

/// `POST /chat-sessions/frontier` request body. `clientRequestId`
/// enables 60s idempotency-keyed dedup per CM5 — retries with the same
/// id return the existing group instead of spawning duplicates. `models`
/// is the per-slot model list (2-3 entries in v0.8; v0.9 ships full
/// 3-pane UI once Gemini joins via agy).
public struct CreateFrontierRequest: Codable, Sendable {
    public let clientRequestId: UUID
    public let models: [FrontierModelSlot]

    public init(clientRequestId: UUID, models: [FrontierModelSlot]) {
        self.clientRequestId = clientRequestId
        self.models = models
    }
}

/// One slot in a Frontier group spawn request — the provider + model +
/// optional Codex backend choice for that pane.
public struct FrontierModelSlot: Codable, Sendable {
    public let provider: AgentKind
    public let model: String?
    public let effort: ReasoningEffort?
    public let codexChatBackend: CodexChatBackend?
    public let chatVendor: ChatVendor?
    public let billingProvider: String?
    /// v14 (Chat V2): per-slot Deep Research toggle. Each broadcast pane
    /// can independently run with deep-research argv. Defaults to false
    /// on older clients (decodeIfPresent).
    public let deepResearch: Bool

    public init(
        provider: AgentKind,
        model: String? = nil,
        effort: ReasoningEffort? = nil,
        codexChatBackend: CodexChatBackend? = nil,
        deepResearch: Bool = false,
        chatVendor: ChatVendor? = nil,
        billingProvider: String? = nil
    ) {
        self.provider = provider
        self.model = model
        self.effort = effort
        self.codexChatBackend = codexChatBackend
        self.deepResearch = deepResearch
        self.chatVendor = chatVendor
        self.billingProvider = billingProvider
    }

    private enum CodingKeys: String, CodingKey {
        case provider, model, effort, codexChatBackend, deepResearch, chatVendor, billingProvider
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.provider = try c.decode(AgentKind.self, forKey: .provider)
        self.model = try c.decodeIfPresent(String.self, forKey: .model)
        self.effort = try c.decodeIfPresent(ReasoningEffort.self, forKey: .effort)
        self.codexChatBackend = try c.decodeIfPresent(CodexChatBackend.self, forKey: .codexChatBackend)
        self.deepResearch = try c.decodeIfPresent(Bool.self, forKey: .deepResearch) ?? false
        // Lenient: an unknown vendor rawValue (a newer client's vendor) decodes
        // to nil instead of failing the whole session decode. Forward-compat —
        // mirrors the wire's decodeIfPresent philosophy.
        self.chatVendor = (try? c.decodeIfPresent(ChatVendor.self, forKey: .chatVendor)) ?? nil
        self.billingProvider = try c.decodeIfPresent(String.self, forKey: .billingProvider)
    }
}

/// `POST /chat-sessions/frontier` response. Per-slot results (E2):
/// each spawn attempt reports ok or failed independently so a partial
/// Frontier (D10) returns the live slots + the failure reasons in one
/// shot. `groupId` is consistent across retries with the same
/// `clientRequestId` (CM5 idempotency).
public struct CreateFrontierResponse: Codable, Sendable {
    public let groupId: UUID
    public let slots: [FrontierSlotResult]

    public init(groupId: UUID, slots: [FrontierSlotResult]) {
        self.groupId = groupId
        self.slots = slots
    }

    /// Slots whose spawn succeeded — used by the UI to gate broadcast
    /// mode (need ≥2) and to know which session ids the first prompt
    /// should fan out to.
    public var successfulSlots: [FrontierSlotResult] {
        slots.filter { $0.isOK }
    }

    /// Slots whose spawn failed (`sessionId == nil`). Surfaces partial
    /// failures so the composer can show why a broadcast degraded.
    public var failedSlots: [FrontierSlotResult] {
        slots.filter { !$0.isOK }
    }

    /// True iff at least two children spawned successfully — broadcast
    /// mode requires multiple providers to compare. The UI should treat
    /// a single-successful response as "broadcast unavailable, surface
    /// the failure reasons" rather than silently degrading to a one-
    /// agent broadcast.
    public var hasMinimumBroadcast: Bool {
        successfulSlots.count >= 2
    }
}

/// One slot's spawn outcome within a Frontier group.
public struct FrontierSlotResult: Codable, Sendable {
    public let index: Int
    /// .ok or .failed — discriminated via `sessionId` (set on ok) vs
    /// `reason` (set on failed).
    public let sessionId: UUID?
    public let reason: String?

    public init(index: Int, sessionId: UUID? = nil, reason: String? = nil) {
        self.index = index
        self.sessionId = sessionId
        self.reason = reason
    }

    public var isOK: Bool { sessionId != nil }
}

/// `POST /chat-sessions/frontier/:groupId/retry-slot` request body.
/// Re-spawns a failed slot per D10 retry affordance.
public struct RetryFrontierSlotRequest: Codable, Sendable {
    public let index: Int

    public init(index: Int) {
        self.index = index
    }
}

/// `POST /chat-sessions/frontier/:groupId/pick-winner` request body.
/// Forks the chosen child into a fresh Solo chat seeded with that
/// child's transcript. Reuses the existing A/B-pair pick-winner pattern.
public struct PickFrontierWinnerRequest: Codable, Sendable {
    public let childIndex: Int

    public init(childIndex: Int) {
        self.childIndex = childIndex
    }
}

/// Non-destructive winner metadata for the comparison UI. This powers
/// the star/check affordance and history stats without archiving losing
/// children; `/pick-winner` remains the destructive "continue from here"
/// operation.
public struct FrontierTurnWinner: Codable, Sendable, Hashable, Identifiable {
    public let groupId: UUID
    public let turnId: String
    public let childIndex: Int
    public let decidedAt: Date

    public var id: String { "\(groupId.uuidString):\(turnId)" }

    public init(groupId: UUID, turnId: String, childIndex: Int, decidedAt: Date = Date()) {
        self.groupId = groupId
        self.turnId = turnId
        self.childIndex = childIndex
        self.decidedAt = decidedAt
    }
}

public struct SetFrontierTurnWinnerRequest: Codable, Sendable {
    public let turnId: String
    public let childIndex: Int

    public init(turnId: String, childIndex: Int) {
        self.turnId = turnId
        self.childIndex = childIndex
    }
}

public struct FrontierSendResponse: Codable, Sendable, Hashable {
    public let groupId: UUID
    public let childCount: Int
    public let results: [FrontierChildSendResult]

    public init(groupId: UUID, childCount: Int, results: [FrontierChildSendResult]) {
        self.groupId = groupId
        self.childCount = childCount
        self.results = results
    }

    public var ok: Bool {
        results.allSatisfy(\.ok)
    }
}

/// `POST /chat-sessions/frontier/:groupId/send` body — extends the
/// solo `SendPromptRequest` with an optional per-child text override.
///
/// Why a separate type: the solo `/sessions/:id/send` body is just
/// `{text, asFollowUp}` and several callers (smoke tests, manual
/// fan-out) depend on that shape. Frontier sends sometimes need
/// per-child prompts so an attachment uploaded to child A's staging
/// dir is referenced as `@/.../A/...` only in child A's prompt, not
/// in child B's prompt (where that path is unreadable).
///
/// `perChildText` is keyed by `sessionId`. If a child's id is missing
/// from the map, the server falls back to the shared `text`. Backward
/// compat: the server also accepts `SendPromptRequest`-shaped bodies
/// for callers that haven't migrated.
public struct FrontierSendRequest: Codable, Sendable {
    public let text: String
    public let asFollowUp: Bool
    public let perChildText: [String: String]?
    public let origin: ProviderPromptOrigin
    public let clientIntentId: String?

    public init(
        text: String,
        asFollowUp: Bool = false,
        perChildText: [UUID: String]? = nil,
        origin: ProviderPromptOrigin = .legacyClient,
        clientIntentId: String? = nil
    ) {
        self.text = text
        self.asFollowUp = asFollowUp
        if let perChildText {
            self.perChildText = Dictionary(uniqueKeysWithValues:
                perChildText.map { ($0.key.uuidString, $0.value) }
            )
        } else {
            self.perChildText = nil
        }
        self.origin = origin
        self.clientIntentId = clientIntentId
    }

    private enum CodingKeys: String, CodingKey {
        case text, asFollowUp, perChildText, origin, clientIntentId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        asFollowUp = try c.decodeIfPresent(Bool.self, forKey: .asFollowUp) ?? false
        perChildText = try c.decodeIfPresent([String: String].self, forKey: .perChildText)
        origin = try c.decodeIfPresent(ProviderPromptOrigin.self, forKey: .origin) ?? .legacyClient
        clientIntentId = try c.decodeIfPresent(String.self, forKey: .clientIntentId)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(text, forKey: .text)
        try c.encode(asFollowUp, forKey: .asFollowUp)
        try c.encodeIfPresent(perChildText, forKey: .perChildText)
        try c.encode(origin, forKey: .origin)
        try c.encodeIfPresent(clientIntentId, forKey: .clientIntentId)
    }

    /// Look up the override for a given child session id; falls back
    /// to the shared `text` when no override is registered.
    public func text(forChild sessionId: UUID) -> String {
        perChildText?[sessionId.uuidString] ?? text
    }
}

public struct FrontierChildSendResult: Codable, Sendable, Hashable {
    public let childIndex: Int
    public let sessionId: UUID
    public let ok: Bool
    public let reason: String?

    public init(childIndex: Int, sessionId: UUID, ok: Bool, reason: String? = nil) {
        self.childIndex = childIndex
        self.sessionId = sessionId
        self.ok = ok
        self.reason = reason
    }
}

/// `frontier-subscribe` WS envelope — typed snapshot per D8 + Codex #5.
/// Emitted on every debounce tick (100ms, same as chat-subscribe). Each
/// envelope is self-contained; consumers replace their state with the
/// latest snapshot rather than diff-applying events.
public struct FrontierGroupSnapshot: Codable, Sendable {
    public let groupId: UUID
    /// Monotonic counter; advances on any child update. Lets the client
    /// debounce its own UI work if it wants.
    public let updateCounter: Int
    public let children: [FrontierChild]
    public let turnWinners: [FrontierTurnWinner]

    public var latestTurnId: String {
        FrontierTurnIdentifier.latest(in: children.map(\.snapshot))
    }

    public init(
        groupId: UUID,
        updateCounter: Int,
        children: [FrontierChild],
        turnWinners: [FrontierTurnWinner] = []
    ) {
        self.groupId = groupId
        self.updateCounter = updateCounter
        self.children = children
        self.turnWinners = turnWinners
    }

    private enum CodingKeys: String, CodingKey {
        case groupId, updateCounter, children, turnWinners
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.groupId = try c.decode(UUID.self, forKey: .groupId)
        self.updateCounter = try c.decode(Int.self, forKey: .updateCounter)
        self.children = try c.decode([FrontierChild].self, forKey: .children)
        self.turnWinners = try c.decodeIfPresent([FrontierTurnWinner].self, forKey: .turnWinners) ?? []
    }
}

/// One child entry inside a `FrontierGroupSnapshot`.
public struct FrontierChild: Codable, Sendable {
    public let childIndex: Int
    public let sessionId: UUID
    public let provider: AgentKind
    public let modelSlug: String
    /// Nil when the child failed to spawn (D10 partial Frontier).
    public let snapshot: WireChatSnapshot?
    public let status: FrontierChildStatus
    public let currentTurnState: TurnState

    public init(
        childIndex: Int,
        sessionId: UUID,
        provider: AgentKind = .unknown,
        modelSlug: String,
        snapshot: WireChatSnapshot? = nil,
        status: FrontierChildStatus,
        currentTurnState: TurnState = .idle
    ) {
        self.childIndex = childIndex
        self.sessionId = sessionId
        self.provider = provider
        self.modelSlug = modelSlug
        self.snapshot = snapshot
        self.status = status
        self.currentTurnState = currentTurnState
    }

    private enum CodingKeys: String, CodingKey {
        case childIndex, sessionId, provider, modelSlug, snapshot, status, currentTurnState
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.childIndex = try c.decode(Int.self, forKey: .childIndex)
        self.sessionId = try c.decode(UUID.self, forKey: .sessionId)
        self.provider = try c.decodeIfPresent(AgentKind.self, forKey: .provider) ?? .unknown
        self.modelSlug = try c.decode(String.self, forKey: .modelSlug)
        self.snapshot = try c.decodeIfPresent(WireChatSnapshot.self, forKey: .snapshot)
        self.status = try c.decode(FrontierChildStatus.self, forKey: .status)
        self.currentTurnState = try c.decodeIfPresent(TurnState.self, forKey: .currentTurnState)
            ?? self.snapshot?.currentTurnState
            ?? .idle
    }
}

public enum FrontierTurnIdentifier {
    public static func latest(in snapshots: [WireChatSnapshot?]) -> String {
        let count = snapshots
            .compactMap { $0 }
            .map { userMessageCount(in: $0.items) }
            .max() ?? 0
        return turnId(forUserMessageCount: count)
    }

    public static func latest(in items: [ChatItem]) -> String {
        turnId(forUserMessageCount: userMessageCount(in: items))
    }

    public static func turnId(forUserMessageCount count: Int) -> String {
        "turn-\(max(count, 0))"
    }

    private static func userMessageCount(in items: [ChatItem]) -> Int {
        items.reduce(into: 0) { count, item in
            guard case .message(let message) = item,
                  message.kind == .userText else { return }
            count += 1
        }
    }
}

/// Per-child status in a Frontier group. Lenient decode for forward-compat.
public enum FrontierChildStatus: String, Codable, Hashable, Sendable, CaseIterable {
    case pending
    case streaming
    case complete
    case failed

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        self = FrontierChildStatus(rawValue: raw) ?? .pending
    }
}

/// `GET /chat-providers` response. Per DG4 capability probe + CM3
/// observer state. Providers render as one row keyed by stable provider id;
/// legacy Codex backend values remain decode-compatible on older payloads.
public struct ChatProvidersResponse: Codable, Sendable {
    public let providers: [ChatProviderEntry]
    public let enabledProviderIDs: [String]?

    public init(providers: [ChatProviderEntry], enabledProviderIDs: [String]? = nil) {
        self.providers = providers
        self.enabledProviderIDs = enabledProviderIDs
    }
}

/// One row in `ChatProvidersResponse`.
public struct ChatProviderEntry: Codable, Sendable {
    public let provider: AgentKind
    /// Legacy Codex backend variant. New probes leave this nil.
    public let codexBackend: CodexChatBackend?
    /// True when the binary / sidecar is present and reachable.
    public let available: Bool
    /// True when the OAuth tokens are present and valid (per the CM3
    /// observer's last check).
    public let authenticated: Bool
    /// True when DG1 + DG4 capability probe passed (no FS mutation,
    /// no shell exec, no network beyond provider; auth file present;
    /// transcript parses to expected shape).
    public let capabilityProbePassed: Bool
    /// ISO8601 timestamp of the last probe run, or nil if never probed.
    public let lastProbedAt: Date?
    /// Optional reason string for `available: false` rows.
    public let reason: String?

    public init(
        provider: AgentKind,
        codexBackend: CodexChatBackend? = nil,
        available: Bool,
        authenticated: Bool,
        capabilityProbePassed: Bool,
        lastProbedAt: Date? = nil,
        reason: String? = nil
    ) {
        self.provider = provider
        self.codexBackend = codexBackend
        self.available = available
        self.authenticated = authenticated
        self.capabilityProbePassed = capabilityProbePassed
        self.lastProbedAt = lastProbedAt
        self.reason = reason
    }
}

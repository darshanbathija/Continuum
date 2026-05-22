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
    /// v5 (2026-05-19) Phase 0a: `WireChatSnapshot.updateCounter` is now
    /// populated from the daemon-owned `SessionChatStore.updateCounter`
    /// (transcript counter) instead of `session.lastEventSeq` (registry/
    /// status counter). The field name and shape are unchanged; only the
    /// semantics shift, so v4 iOS clients keep working. Phase 0a also
    /// introduces the `chat-subscribe` WS op (lands in Phase 2).
    /// v6 (2026-05-19) Gemini provider: extends `AgentKind` with `.gemini`;
    /// `ModelCatalog` gains `gemini` array; `/usage` envelope ships in
    /// dual-shape (legacy `{claude, codex}` + new `usage: [String: UsageData]`
    /// dict) with PER-PROVIDER fallback in v6 readers (X1 fix: prefer
    /// `usage[id]`, fall back to legacy `<id>` for each provider
    /// independently — prevents data-loss when dict is partial).
    /// v7 (2026-05-20) Antigravity 2 native: new `/sessions/:id/antigravity-plan`
    /// REST endpoint + `antigravity-plan-subscribe` WS op; new
    /// `AntigravityPlanSnapshot` DTO. `UsageData` gains optional
    /// `antigravityModel: String?` + `sdkModeActive: Bool?` fields
    /// (decodeIfPresent; back-compat preserved). The `usage[id]` dict key
    /// STAYS "gemini" through v7 per locked decision D5 — never rename
    /// to "antigravity" because v6 iOS clients use the per-provider
    /// fallback that keys on "gemini" literally; renaming would silently
    /// strand iOS data.
    /// v8 (2026-05-20) Codex SDK observation mode: `UsageData` gains
    /// optional `codexSDKModeActive: Bool?` field (decodeIfPresent —
    /// back-compat preserved). New `codexSDKMinimum = 8` gate +
    /// `supportsCodexSDK(serverWireVersion:)` helper. No new endpoints
    /// or WS ops in v8 — the SDK observation mode rides on the existing
    /// `/usage` envelope; the field tells iOS to render "· SDK mode" on
    /// the Codex analytics subtitle.
    /// v9 (2026-05-21) Chat tab: new endpoints (POST /chat-sessions,
    /// POST /chat-sessions/frontier/*, GET /chat-providers) + Frontier
    /// WS op (`frontier-subscribe`). AgentSession schema v5 adds
    /// optional `kind`, `frontierGroupId`, `frontierChildIndex`,
    /// `codexChatBackend`, `codexChatThreadId`; `repoKey` becomes
    /// optional. New `chatMinimum/frontierMinimum/codexChatBackendMinimum`
    /// = 9 gates. iOS Chat tab gates on `serverWireVersion >= chatMinimum`.
    /// v10 (2026-05-21) Antigravity 2 native chat via `agentapi`:
    /// `AgentSession` gains optional `geminiBackend: GeminiBackend?`
    /// + `antigravityConversationId: UUID?` (schema v5→v6). `usage[id]`
    /// dict key transitions from `"gemini"` literal to `"antigravity"`,
    /// with dual-decoder fallback (`usage["antigravity"]` first →
    /// `usage["gemini"]`). New `agentapiMinimum = 10` +
    /// `antigravityChatMinimum = 11` (deferred to v0.8.2 until daemon
    /// POST /sessions also dispatches via agentapi — Codex P1.4).
    /// Gates surface "Update Clawdmeter on Mac" copy on older iOS
    /// instead of letting them render a stale Gemini UI.
    /// v11 (2026-05-21) Gemini chat live via daemon: POST /chat-sessions
    /// now dispatches `provider: "gemini"` to agentapi (lifts the v0.8
    /// 501 stub). `AgentSession` gains optional `antigravityProjectId:
    /// String?` (additive — decoder-tolerant, no formal schema bump).
    /// `antigravityChatMinimum = 11` is now reachable.
    /// v12 (2026-05-22, X3 hardening for PR #28 OpenCode): `AgentKind`
    /// gains a `.unknown` sentinel + the decoder folds unknown raws
    /// into it instead of `.claude`. Older v11 clients reading a v13
    /// (OpenCode) payload still drop into the silently-mislabeled
    /// `.claude` path — they get the audit-flagged bug. v12+ clients
    /// reading v13 payloads render the new kind as "Other agent" via
    /// the UI fallback rather than misclassifying.
    /// v13 (2026-05-22, D11/D12 — OpenCode adapter): adds
    /// `AgentKind.opencode` + `UsageRecord.Provider.opencode`. v12
    /// clients decode the new raw as `.unknown` (the X3 fallback);
    /// v13+ clients decode as `.opencode` natively. Schema migration
    /// audited across `AnalyticsDailyChart` + every `byProvider:`
    /// consumer.
    /// v14 (2026-05-23, Chat V2): explicit per-turn lifecycle on the
    /// snapshot wire (`WireChatSnapshot.currentTurnState: TurnState`)
    /// emitted from each provider's natural end-marker (Claude's
    /// `result` line, Codex SDK's `turn.completed`, Antigravity's
    /// `chunk_done`). New Deep Research toggle on
    /// `CreateChatSessionRequest`, `FrontierModelSlot`, and the
    /// `AgentSession` registry record (so the bool survives respawn
    /// / restore / retry). New `GET /chat-sessions/search?q=` history
    /// search endpoint walking JSONL on disk. All additive +
    /// decodeIfPresent: older Macs/clients see decode-default values
    /// without crashing.
    public static let current: Int = 14
    /// Minimum wire version that exposes `AgentKind.opencode` natively.
    /// Clients with `serverWireVersion < this` decode opencode sessions
    /// as `.unknown` (X3 fallback) and render as "Other agent". This is
    /// the gate the Mac uses to suppress OpenCode-related controls when
    /// the paired iPhone is too old to render them correctly.
    public static let opencodeMinimum: Int = 13
    /// Minimum wire version that supports the `compose-draft` WS op.
    /// iOS guards `postComposeDraft` on this — older Macs would reject
    /// the unknown op via `.unsupportedData` close (review §10 finding).
    public static let composeDraftMinimum: Int = 4
    /// Minimum wire version that supports the `chat-subscribe` WS op
    /// (Phase 2 push-based chat snapshot delivery, replacing iOS 3s HTTP
    /// polling). iOS guards WS subscribe on this — older Macs stay on
    /// the `/chat-snapshot` HTTP polling path.
    public static let chatSubscribeMinimum: Int = 5
    /// Minimum wire version that exposes `AgentKind.gemini` + the
    /// `usage` dict shape on `/usage`. iOS hides Gemini UI when
    /// `serverWireVersion < this` and surfaces an "Update Clawdmeter on
    /// Mac" banner instead of dropping into a confused state.
    public static let geminiMinimum: Int = 6

    /// Minimum wire version that supports the Antigravity Plan endpoint
    /// + WS subscribe op (v7 — Antigravity 2 native release). iOS hides
    /// the Plan tab when `serverWireVersion < this` and shows
    /// "Update Clawdmeter on Mac for the Plan tab" copy instead.
    public static let antigravityMinimum: Int = 7

    /// Minimum wire version that surfaces the Codex SDK mode toggle
    /// state via `UsageData.codexSDKModeActive` (v8). Older Macs paired
    /// with a v8 iOS hide the "· SDK mode" subtitle and assume Disk
    /// mode by default.
    public static let codexSDKMinimum: Int = 8

    /// Minimum wire version that supports the Chat tab endpoints
    /// (`POST /chat-sessions`, `GET /chat-providers`, schema v5 fields).
    /// iOS hides the Chat tab when `serverWireVersion < this`.
    public static let chatMinimum: Int = 9

    /// Minimum wire version that supports Frontier compare endpoints
    /// (`POST /chat-sessions/frontier/*`, `frontier-subscribe` WS op).
    /// Daemon endpoints ship in v0.8 for forward-compat; the Mac/iOS UI
    /// lands in v0.9 alongside the Antigravity (agy) replacement for
    /// gemini CLI.
    public static let frontierMinimum: Int = 9

    /// Minimum wire version that supports the per-session Codex chat
    /// backend choice (`AgentSession.codexChatBackend`). Older Macs
    /// ignore the per-request override.
    public static let codexChatBackendMinimum: Int = 9

    /// Minimum wire version that supports spawning Gemini sessions via
    /// Antigravity 2's `agentapi` HTTP-RPC (v10). Older Macs can't host
    /// these sessions — iOS hides the agentapi spawn path and surfaces
    /// "Update Clawdmeter on Mac" copy. v0.42 quota fallback (D9) still
    /// works on older Macs because quota is a separate, read-only path.
    public static let agentapiMinimum: Int = 10

    /// Minimum wire version at which the daemon's chat surface dispatches
    /// Gemini through `agentapi`. v0.8.1 (wire v10) migrated the Mac UI's
    /// spawn path (`SessionsView.spawnAntigravitySession`); v0.9 (wire v11)
    /// adds a daemon-side `handlePostGeminiChatSession` that lifts the v0.8
    /// 501 stub on `POST /chat-sessions {provider: "gemini"}`. iOS gates
    /// the Gemini chat row on this so older Macs (wire v10 or below)
    /// surface a "v0.9 required" CTA instead of letting users try a
    /// POST that returns 501.
    public static let antigravityChatMinimum: Int = 11

    /// Minimum wire version that exposes the per-turn lifecycle field
    /// `WireChatSnapshot.currentTurnState`. Older daemons send snapshots
    /// without the field; lenient decoder defaults to `.idle` so iOS
    /// keeps working but the Stopwatch + Stop→Send transitions
    /// fall back to a heuristic (no new event in 2s = done). Used by
    /// the ChatV2 status strip to detect whether the heuristic
    /// fallback is needed.
    public static let turnLifecycleMinimum: Int = 14

    /// Minimum wire version that honors the `deepResearch` field on
    /// `CreateChatSessionRequest` / `FrontierModelSlot`. Older Macs
    /// decode the field as `false` (decodeIfPresent default) so the
    /// session lands as a regular send. iOS surfaces a warning when
    /// the user enables Deep Research against a too-old paired Mac.
    public static let deepResearchMinimum: Int = 14

    /// Minimum wire version that supports `GET /chat-sessions/search?q=`.
    /// Older Macs 404; clients fall back to grepping the local LRU cache
    /// (which only covers the most-recent 2 conversations on iOS, 20 on
    /// Mac) and label results "Recent only".
    public static let chatSearchMinimum: Int = 14

    /// Forward-compat client-side check (X3-A). Returns `true` when the
    /// client should flag a mismatch banner. The contract is *forward-
    /// compatible*: newer servers (e.g. wire v7) work fine with this
    /// client; per-feature gates (`supportsGemini`, `supportsChatSubscribe`,
    /// `supportsComposeDraft`) handle the feature surface. Only true when
    /// the server is genuinely too old for the minimum feature floor
    /// (`composeDraftMinimum`).
    ///
    /// - Parameter serverWireVersion: the version the paired Mac reports
    ///   on `/health`. `nil` means we haven't heard from the Mac yet —
    ///   that's not a mismatch.
    /// - Returns: `true` only when `serverWireVersion < composeDraftMinimum`.
    public static func hasMismatch(serverWireVersion: Int?) -> Bool {
        guard let v = serverWireVersion else { return false }
        return v < composeDraftMinimum
    }

    public static func supportsGemini(serverWireVersion: Int?) -> Bool {
        guard let v = serverWireVersion else { return false }
        return v >= geminiMinimum
    }

    public static func supportsChatSubscribe(serverWireVersion: Int?) -> Bool {
        guard let v = serverWireVersion else { return false }
        return v >= chatSubscribeMinimum
    }

    public static func supportsComposeDraft(serverWireVersion: Int?) -> Bool {
        guard let v = serverWireVersion else { return false }
        return v >= composeDraftMinimum
    }

    /// Whether the paired Mac is wire v7+ and therefore exposes
    /// `/sessions/:id/antigravity-plan` + the `antigravity-plan-subscribe`
    /// WS op. Used by iOS to gate the Plan tab visibility.
    public static func supportsAntigravityPlan(serverWireVersion: Int?) -> Bool {
        guard let v = serverWireVersion else { return false }
        return v >= antigravityMinimum
    }

    /// Whether the paired Mac is wire v8+ and therefore reports the
    /// Codex SDK mode toggle state via `UsageData.codexSDKModeActive`.
    /// Used by iOS to render "· SDK mode" vs "· disk mode" on the Codex
    /// analytics subtitle. When false, iOS assumes disk mode.
    public static func supportsCodexSDK(serverWireVersion: Int?) -> Bool {
        guard let v = serverWireVersion else { return false }
        return v >= codexSDKMinimum
    }

    /// Whether the paired Mac is wire v9+ and therefore exposes the
    /// Chat tab endpoints. iOS gates Chat tab visibility on this.
    public static func supportsChat(serverWireVersion: Int?) -> Bool {
        guard let v = serverWireVersion else { return false }
        return v >= chatMinimum
    }

    /// Whether the paired Mac is wire v9+ and therefore exposes the
    /// Frontier endpoints. iOS gates the (v0.9) Frontier UI on this.
    public static func supportsFrontier(serverWireVersion: Int?) -> Bool {
        guard let v = serverWireVersion else { return false }
        return v >= frontierMinimum
    }

    /// Whether the paired Mac is wire v9+ and therefore honors the
    /// per-request `codexChatBackend` override on `POST /chat-sessions`.
    public static func supportsCodexChatBackend(serverWireVersion: Int?) -> Bool {
        guard let v = serverWireVersion else { return false }
        return v >= codexChatBackendMinimum
    }

    /// Whether the paired Mac is wire v11+ and therefore exposes
    /// Antigravity 2 chat via the daemon's `POST /sessions` endpoint.
    /// v0.8.1 (wire v10) migrated only the Mac UI's spawn path; iOS's
    /// daemon-initiated start path waits for v0.8.2 (wire v11). When
    /// false, iOS surfaces "Update Clawdmeter on Mac" instead of
    /// posting to an endpoint that lands in legacy tmux argv.
    public static func supportsAntigravityChat(serverWireVersion: Int?) -> Bool {
        guard let v = serverWireVersion else { return false }
        return v >= antigravityChatMinimum
    }

    /// Whether the paired Mac is wire v14+ and therefore emits per-turn
    /// lifecycle transitions on `WireChatSnapshot.currentTurnState`. iOS
    /// ChatV2 reads this to know whether to trust the field (vs falling
    /// back to a heartbeat heuristic).
    public static func supportsTurnLifecycle(serverWireVersion: Int?) -> Bool {
        guard let v = serverWireVersion else { return false }
        return v >= turnLifecycleMinimum
    }

    /// Whether the paired Mac honors the `deepResearch` field on chat
    /// create requests. Older Macs decode it but ignore it; the V2
    /// composer surfaces a banner instead of letting Deep Research
    /// silently degrade.
    public static func supportsDeepResearch(serverWireVersion: Int?) -> Bool {
        guard let v = serverWireVersion else { return false }
        return v >= deepResearchMinimum
    }

    /// Whether the paired Mac exposes the `GET /chat-sessions/search`
    /// endpoint. The V2 sidebar uses this for full-history search;
    /// when false, the sidebar reverts to grepping the local LRU cache
    /// and labels the result "Recent only".
    public static func supportsChatSearch(serverWireVersion: Int?) -> Bool {
        guard let v = serverWireVersion else { return false }
        return v >= chatSearchMinimum
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
    /// Gemini Code Assist models. Empty on v5 wire (decoder fallback below
    /// supplies `[]`); populated on v6+. Models reflect what Antigravity's
    /// `cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels`
    /// surfaces — 3-flavor split between Pro/Flash/Flash-Lite.
    public let gemini: [ModelCatalogEntry]
    public let updatedAt: Date

    public init(claude: [ModelCatalogEntry], codex: [ModelCatalogEntry], gemini: [ModelCatalogEntry] = [], updatedAt: Date) {
        self.claude = claude
        self.codex = codex
        self.gemini = gemini
        self.updatedAt = updatedAt
    }

    /// Bundled default catalog. Mirrors the user's Conductor screenshot:
    /// Opus 4.7 / Opus 4.7 1M / Opus 4.6 1M / Sonnet 4.6 / Haiku 4.5 +
    /// GPT-5.5 / GPT-5.4 / GPT-5.3-Codex-Spark / GPT-5.3-Codex / GPT-5.2-Codex.
    /// Gemini entries reflect Antigravity's 2026-05-19 v1internal:fetchAvailableModels
    /// response (Gemini 3.1 Pro High/Low + Gemini 3 Flash).
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
        gemini: [
            // Antigravity 2's default model (resolves from the
            // `MODEL_PLACEHOLDER_M133` opaque token in
            // ~/.gemini/antigravity/antigravity_state.pbtxt). First in the
            // list so `ModelCatalog.bundled.gemini.first?.id` picks it up
            // as the default for new sessions. Pricing row already in
            // pricing.json under the same id.
            ModelCatalogEntry(id: "gemini-3.5-flash",          provider: .gemini, displayName: "Gemini 3.5 Flash",            cliAlias: "flash-3.5",          supportsThinking: false, supportsEffort: false, contextWindow: 1_000_000, recommendedFor: "Antigravity 2 default",  badge: "New"),
            // v0.7.17: Gemini 3.5 Flash's "Extended" thinking mode —
            // matches the Standard/Extended picker Google ships in the
            // Antigravity UI. Same base model, but the CLI passes the
            // `-thinking` suffix so the API enables the higher
            // thinking_budget configuration. Standard = 0 budget,
            // Extended ≈ 24576 tokens of thinking before the answer
            // turn (per Google's published thinking_config spec).
            ModelCatalogEntry(id: "gemini-3.5-flash-thinking", provider: .gemini, displayName: "Gemini 3.5 Flash (Thinking)", cliAlias: "flash-3.5-thinking", supportsThinking: true,  supportsEffort: false, contextWindow: 1_000_000, recommendedFor: "Complex problem solving", badge: "Thinking"),
            ModelCatalogEntry(id: "gemini-3-pro",              provider: .gemini, displayName: "Gemini 3 Pro",                cliAlias: "pro",                supportsThinking: true,  supportsEffort: false, contextWindow: 2_000_000, recommendedFor: "Deep reasoning",         badge: "Pro"),
            ModelCatalogEntry(id: "gemini-3.1-pro-high",       provider: .gemini, displayName: "Gemini 3.1 Pro (High)",       cliAlias: "pro-high",           supportsThinking: true,  supportsEffort: false, contextWindow: 1_000_000, recommendedFor: "Deep reasoning",         badge: "High"),
            ModelCatalogEntry(id: "gemini-3.1-pro-low",        provider: .gemini, displayName: "Gemini 3.1 Pro (Low)",        cliAlias: "pro",                supportsThinking: false, supportsEffort: false, contextWindow: 1_000_000, recommendedFor: "Most work",              badge: nil),
            ModelCatalogEntry(id: "gemini-3-flash",            provider: .gemini, displayName: "Gemini 3 Flash",              cliAlias: "flash",              supportsThinking: false, supportsEffort: false, contextWindow: 1_000_000, recommendedFor: "Fast iteration",         badge: "Fast"),
            // v0.7.17: same Standard/Extended split as 3.5 Flash above.
            ModelCatalogEntry(id: "gemini-3-flash-thinking",   provider: .gemini, displayName: "Gemini 3 Flash (Thinking)",   cliAlias: "flash-thinking",     supportsThinking: true,  supportsEffort: false, contextWindow: 1_000_000, recommendedFor: "Complex problem solving", badge: "Thinking"),
        ],
        updatedAt: Date(timeIntervalSince1970: 1747353600) // 2026-05-15
    )

    /// Resolve a model id to a catalog entry across all providers.
    public func entry(forId id: String) -> ModelCatalogEntry? {
        claude.first(where: { $0.id == id || $0.cliAlias == id })
            ?? codex.first(where: { $0.id == id || $0.cliAlias == id })
            ?? gemini.first(where: { $0.id == id || $0.cliAlias == id })
    }

    // MARK: - Codable

    /// Custom decoder so v5 payloads (no `gemini` field) decode cleanly.
    /// Mirror of TokenTotals' X2 fix at the catalog level — synthesized
    /// Codable throws on missing keys; decodeIfPresent + default returns
    /// an empty Gemini array.
    private enum CodingKeys: String, CodingKey {
        case claude, codex, gemini, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.claude = try c.decode([ModelCatalogEntry].self, forKey: .claude)
        self.codex = try c.decode([ModelCatalogEntry].self, forKey: .codex)
        self.gemini = try c.decodeIfPresent([ModelCatalogEntry].self, forKey: .gemini) ?? []
        self.updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(claude, forKey: .claude)
        try c.encode(codex, forKey: .codex)
        try c.encode(gemini, forKey: .gemini)
        try c.encode(updatedAt, forKey: .updatedAt)
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
    /// User-supplied memorable name. When non-empty wins over `firstPrompt`
    /// as the sidebar row title. Persisted on the Mac in
    /// `~/.clawdmeter/jsonl-aliases.json` keyed by `path`.
    public let customName: String?
    public var id: String { path }

    public init(
        path: String,
        lastModified: Date,
        provider: AgentKind,
        firstPrompt: String? = nil,
        customName: String? = nil
    ) {
        self.path = path
        self.lastModified = lastModified
        self.provider = provider
        self.firstPrompt = firstPrompt
        self.customName = customName
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.path = try c.decode(String.self, forKey: .path)
        self.lastModified = try c.decode(Date.self, forKey: .lastModified)
        self.provider = try c.decode(AgentKind.self, forKey: .provider)
        self.firstPrompt = try c.decodeIfPresent(String.self, forKey: .firstPrompt)
        // v0.5.10 addition. Decoder-tolerant — older clients omit the field.
        self.customName = try c.decodeIfPresent(String.self, forKey: .customName)
    }

    private enum CodingKeys: String, CodingKey {
        case path, lastModified, provider, firstPrompt, customName
    }
}

/// `POST /jsonl-aliases/rename` body. Sent from iOS to the Mac daemon to
/// rename a Recent JSONL row. `name` nil-or-empty clears the alias.
public struct RenameJSONLRequest: Codable, Sendable {
    public let path: String
    public let name: String?

    public init(path: String, name: String?) {
        self.path = path
        self.name = name
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
    /// Gemini Code Assist via Google's `gemini` CLI. Added in wire v6
    /// (2026-05-19).
    case gemini
    /// OpenCode adapter (D11/D12, v1.1 — wire v13). The Mac spawns a
    /// shared `opencode serve` process (P1 singleton) and registers
    /// per-Clawdmeter-session SSE clients against it. Underlying model
    /// is provider-of-the-user's-choice (Anthropic, OpenAI, Google);
    /// analytics tag the spend under `.opencode` regardless.
    case opencode
    /// Forward-compat sentinel for unknown agent kinds (X3, v0.17, wire
    /// v12). Older v12 clients connecting to a v13 Mac decode the
    /// `.opencode` raw into `.unknown` instead of `.claude` —
    /// preventing the silent mislabeling Codex flagged in the
    /// eng-review. UI sites render `.unknown` as a neutral
    /// "Other agent" tile.
    ///
    /// `.unknown` is intentionally NOT user-selectable (`allCases`
    /// excludes it via the custom override below); it only appears on
    /// the read path when decoding payloads we don't recognize.
    case unknown = "__unknown__"

    /// Filter `.unknown` out of `allCases` so pickers and provider
    /// segmented controls don't accidentally render it as a choice.
    /// `.opencode` is included — v13 clients render it as a real
    /// picker option.
    public static var allCases: [AgentKind] {
        [.claude, .codex, .gemini, .opencode]
    }

    /// Lenient decoder (X3 — wire v12). Forward-compat readers keep
    /// parsing payloads from newer Macs whose `agent` field carries a
    /// value this binary doesn't recognize. Unknown raws fold to
    /// `.unknown` so UI surfaces show "Other agent" instead of
    /// silently mislabeling as Claude.
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        self = AgentKind(rawValue: raw) ?? .unknown
    }
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

/// Top-level session category (v0.8 schema v5). Distinguishes coding
/// sessions (the existing v0.7.x flow that owns a repo + worktree) from
/// chat sessions (the new v0.8 Chat tab — empty cwd, plan-mode, no repo).
/// Default `.code` on decode so v3/v4 sessions.json files round-trip
/// unchanged.
public enum SessionKind: String, Codable, Hashable, Sendable, CaseIterable {
    case code
    case chat

    /// Lenient decoder. Unknown raws (forward-compat) fall back to `.code`
    /// rather than throwing.
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        self = SessionKind(rawValue: raw) ?? .code
    }
}

/// Per-session backend choice for Codex chat (v0.8 schema v5 + RE1
/// resolution). Customer-selectable; default is `.sdk` because the SDK
/// surfaces typed events + multi-subscriber + iOS handoff. CLI is the
/// uniform-with-Claude fallback for users who hit SDK provisioning
/// trouble or just prefer the tmux path.
///
/// **Per-session pinning**: the backend chosen at spawn time is stored on
/// the AgentSession and used for the lifetime of that chat. Flipping the
/// global default in Settings does not migrate live sessions.
public enum CodexChatBackend: String, Codable, Hashable, Sendable, CaseIterable {
    case sdk
    case cli

    /// Lenient decoder. Unknown raws fall back to `.sdk` (the default).
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        self = CodexChatBackend(rawValue: raw) ?? .sdk
    }
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
// MARK: - Gemini backend (v10 agy-migration)

/// Which transport drives a Gemini session.
///
/// `nil` (the default for any v0.7-era session that's been persisted) means
/// "legacy / pre-agy-migration" — at the time those sessions were created,
/// only the standalone `gemini` CLI v0.42 existed. v0.8.0 onwards uses
/// `.agentapi` (Antigravity 2's HTTP-RPC mode) for all new Gemini sessions
/// when Antigravity.app is reachable (D4 hard-stop: no spawn otherwise).
/// v0.42 is no longer a chat fallback; it stays in the install only as a
/// no-op for users who haven't installed Antigravity 2 yet (they get a
/// CTA, not a session).
///
/// This is a transport axis, NOT an agent-kind axis — `AgentSession.kind`
/// (per chat-tab v0.8) means `.code` vs `.chat` and stays orthogonal.
public enum GeminiBackend: String, Codable, Hashable, Sendable, CaseIterable {
    /// Antigravity 2's `agentapi` HTTP-RPC mode. Conversations live in
    /// `~/.gemini/antigravity/conversations/<id>.db` (SQLite WAL).
    case agentapi
}

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

    /// v0.5.4: user-supplied display name. When set, replaces
    /// `repoDisplayName` in the sidebar row + chat header so the session
    /// can be labeled by what it's actually working on rather than just
    /// the repo name. Empty / whitespace-only strings normalize to nil
    /// at the daemon's rename handler.
    public let customName: String?

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
    /// For Codex-SDK chat sessions, the server-side threadId returned by
    /// the SDK on first turn. Persisted across DG3 idle-evictions so the
    /// daemon can call `CodexSubscriptionRelay.start(threadId:)` on
    /// reopening and reconstruct the same conversation (NEW-T13 verified).
    /// Nil for CLI chat and code sessions.
    public let codexChatThreadId: String?

    // MARK: - Schema v6 additions (v0.8.1 agy-migration, wire v10)
    //
    // Both optional + decoder-tolerant so v3/v4/v5 sessions.json files
    // decode cleanly. Downgrade path: older readers (which know no
    // GeminiBackend or antigravityConversationId) silently drop these
    // fields — same back-compat pattern as schema v3's effort fields.

    /// Which transport drives this Gemini session. `nil` for any session
    /// created before agy-migration (those were spawned via `gemini`
    /// v0.42 CLI; the binary may still be on disk but Clawdmeter doesn't
    /// re-spawn them in v0.8.1+). `.agentapi` means the session was
    /// created via Antigravity 2's HTTP-RPC and lives in a SQLite WAL
    /// DB under `~/.gemini/antigravity/conversations/`.
    /// Only meaningful when `agent == .gemini`. For Claude/Codex it
    /// stays nil.
    public let geminiBackend: GeminiBackend?

    /// Antigravity's conversation UUID, returned by
    /// `language_server agentapi new-conversation` and used to:
    ///   - resume the conversation across Clawdmeter restarts
    ///   - target `agentapi send-message <conv-id> <prompt>` calls
    ///   - locate the SQLite DB file
    ///   - thread iOS send-message round-trips
    /// `nil` for any non-agentapi session.
    public let antigravityConversationId: UUID?

    /// v0.9 — Antigravity's project UUID. Persisted on the session at
    /// create time so chat sessions (no `repoKey`) can resolve at
    /// send-time without going through repoKey-based project lookup.
    /// Pre-v0.9 sessions = nil; sendAntigravityMessage falls back to
    /// `AntigravityProjectResolver.resolve(forRepoKey:)` for those.
    public let antigravityProjectId: String?

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

    /// When true, this chat session was spawned with Deep Research argv
    /// (Claude `--allowedTools WebSearch,WebFetch,... --append-system-prompt`,
    /// Codex SDK `tools: ["web_search"] + modelReasoningEffort: "xhigh"`,
    /// or Gemini agentapi `gemini-3-pro` + deep-research system instruction).
    /// Defaults to false on older sessions.
    public let deepResearch: Bool

    public init(
        id: UUID,
        repoKey: String?,
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
        abPairDecidedAt: Date? = nil,
        customName: String? = nil,
        kind: SessionKind = .code,
        frontierGroupId: UUID? = nil,
        frontierChildIndex: Int? = nil,
        codexChatBackend: CodexChatBackend? = nil,
        codexChatThreadId: String? = nil,
        geminiBackend: GeminiBackend? = nil,
        antigravityConversationId: UUID? = nil,
        antigravityProjectId: String? = nil,
        deepResearch: Bool = false
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
        self.customName = customName
        self.kind = kind
        self.frontierGroupId = frontierGroupId
        self.frontierChildIndex = frontierChildIndex
        self.codexChatBackend = codexChatBackend
        self.codexChatThreadId = codexChatThreadId
        self.geminiBackend = geminiBackend
        self.antigravityConversationId = antigravityConversationId
        self.antigravityProjectId = antigravityProjectId
        self.deepResearch = deepResearch
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
        // v0.5.4 schema addition: customName. Optional + decoder-tolerant
        // so v3 sessions.json files decode cleanly (the field just stays
        // nil).
        self.customName = (try? c.decodeIfPresent(String.self, forKey: .customName)) ?? nil
        // v0.8.0 schema v5 additions: kind, frontierGroupId, frontierChildIndex,
        // codexChatBackend, codexChatThreadId. All optional + decoder-tolerant
        // so v3/v4 sessions.json files decode unchanged (defaults below).
        self.kind = (try? c.decodeIfPresent(SessionKind.self, forKey: .kind)) ?? .code
        self.frontierGroupId = (try? c.decodeIfPresent(UUID.self, forKey: .frontierGroupId)) ?? nil
        self.frontierChildIndex = (try? c.decodeIfPresent(Int.self, forKey: .frontierChildIndex)) ?? nil
        self.codexChatBackend = (try? c.decodeIfPresent(CodexChatBackend.self, forKey: .codexChatBackend)) ?? nil
        self.codexChatThreadId = (try? c.decodeIfPresent(String.self, forKey: .codexChatThreadId)) ?? nil
        // v0.8.1 schema v6 additions (agy-migration). Same decoder-
        // tolerant pattern as effort/abPair fields: any earlier-schema
        // sessions.json decodes cleanly with these as nil. v0.7-era
        // Gemini sessions = `geminiBackend == nil` (legacy v0.42 era);
        // v0.8.1+ Gemini sessions = `.agentapi`.
        self.geminiBackend = (try? c.decodeIfPresent(GeminiBackend.self, forKey: .geminiBackend)) ?? nil
        self.antigravityConversationId = (try? c.decodeIfPresent(UUID.self, forKey: .antigravityConversationId)) ?? nil
        // v0.9 schema addition: antigravityProjectId. Persists the agentapi
        // ANTIGRAVITY_PROJECT_ID on the session so chat sessions (no repoKey)
        // can resolve at send-time without a forRepoKey lookup. Optional +
        // decoder-tolerant: any v0.8.1 sessions.json decodes cleanly with
        // this nil; sendAntigravityMessage falls back to the repoKey path.
        self.antigravityProjectId = (try? c.decodeIfPresent(String.self, forKey: .antigravityProjectId)) ?? nil
        // v0.23 schema v7 addition: deepResearch. Persisted so respawn/
        // restore/retry preserves the flag. Older sessions.json files
        // decode this as false.
        self.deepResearch = (try? c.decodeIfPresent(Bool.self, forKey: .deepResearch)) ?? false
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
        if let wt = worktreePath, !wt.isEmpty { return wt }
        if let rk = repoKey, !rk.isEmpty { return rk }
        preconditionFailure("AgentSession \(id) has neither worktreePath nor repoKey — daemon spawned an invalid session (kind=\(kind))")
    }

    private enum CodingKeys: String, CodingKey {
        case id, repoKey, repoDisplayName, agent, model, goal,
             worktreePath, tmuxWindowId, tmuxPaneId,
             status, planText, createdAt, lastEventAt, lastEventSeq,
             mode, archivedAt,
             terminalPanes, scheduledFollowUps, parentSessionId,
             effort, abPairSessionId, abPairDecidedAt,
             customName,
             // v0.8.0 schema v5 (Chat tab).
             kind, frontierGroupId, frontierChildIndex,
             codexChatBackend, codexChatThreadId,
             // v0.8.1 schema v6 (agy-migration).
             geminiBackend, antigravityConversationId,
             // v0.9 schema addition (chat-via-agentapi).
             antigravityProjectId,
             // v0.23 schema v7 (Chat V2 Deep Research).
             deepResearch
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

    public init(
        repoKey: String,
        agent: AgentKind,
        model: String? = nil,
        planMode: Bool = false,
        goal: String? = nil,
        useWorktree: Bool = true,
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
        // v0.7.9: default flipped to true. Older v6/v7 clients that
        // omit the field now opt into worktrees automatically — same
        // behaviour as the v0.7.9+ UI which has no explicit mode chip.
        self.useWorktree = (try? c.decode(Bool.self, forKey: .useWorktree)) ?? true
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
/// it via tmux, and clears the pending prompt on the session's store.
public struct PermissionRespondRequest: Codable, Sendable {
    public let promptId: String
    public let optionId: String

    public init(promptId: String, optionId: String) {
        self.promptId = promptId
        self.optionId = optionId
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
    /// v0.14.0 (plan v2.1): TCP port on the Mac that fronts the Open Design
    /// daemon via DesignPortForwarder. Optional — older Mac builds omit it
    /// and iOS falls back to the empty-state pairing CTA.
    public let designPort: Int?
    /// v0.14.0 (plan v2.1 T19): per-pairing HKDF-derived design credential.
    /// Stable across daemon restarts, revocable via PairingTokenStore.
    public let designToken: String?

    public init(host: String, port: Int, wsPort: Int, token: String,
                designPort: Int? = nil, designToken: String? = nil) {
        self.host = host
        self.port = port
        self.wsPort = wsPort
        self.token = token
        self.designPort = designPort
        self.designToken = designToken
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
    /// Legacy top-level fields — kept for v5 clients reading a v6 server.
    /// v6+ clients prefer the `usage` dict below; legacy is the fallback
    /// path. See plan E2/X1 wire dual-shape contract.
    public let claude: UsageData?
    public let codex: UsageData?
    /// Per-provider dict added in wire v6 (2026-05-19 Gemini provider).
    /// Keyed by `providerID` (matches `UsageRecord.Provider.rawValue`).
    /// v6 clients prefer this dict per-provider, falling back to the
    /// legacy fields independently per provider (X1 fix: per-provider
    /// fallback prevents data-loss when the dict is partial — e.g.
    /// `{usage: {gemini: …}}` without `claude`/`codex` keys still lets
    /// legacy fields carry those providers through).
    public let usage: [String: UsageData]?
    /// Server-side wall-clock when the snapshot was assembled. The
    /// iPhone uses this to age the gauges ("Last checked X ago") so
    /// the user knows when the Mac last actually polled the providers.
    public let lastChecked: Date

    public init(
        claude: UsageData?,
        codex: UsageData?,
        usage: [String: UsageData]? = nil,
        lastChecked: Date
    ) {
        self.claude = claude
        self.codex = codex
        self.usage = usage
        self.lastChecked = lastChecked
    }

    /// Per-provider read with E2/X1 fallback semantics. v6 clients call
    /// this once per provider; the implementation prefers the dict and
    /// falls back to legacy fields independently for each id, preventing
    /// data-loss when the dict is partial.
    ///
    /// v10 (agy-migration): the "gemini" provider key transitioned to
    /// "antigravity" to match the agentapi naming. The dual-key fallback
    /// preserves v8/v9 iOS readers — a v8 iOS asking for "gemini" still
    /// receives the data even when a v10 Mac wrote it under
    /// "antigravity", and vice versa. The provider id "gemini" stays the
    /// canonical id at the iOS callsite; the wire just shifted the key.
    public func usageData(for providerID: String) -> UsageData? {
        if let dict = usage {
            // Direct hit.
            if let snapshot = dict[providerID] { return snapshot }
            // v10 dual-key bridge. Gemini provider data may be under
            // either "gemini" (v6-v9 servers) or "antigravity" (v10+).
            // Both directions resolve cleanly.
            if providerID == "gemini",      let snapshot = dict["antigravity"] { return snapshot }
            if providerID == "antigravity", let snapshot = dict["gemini"]      { return snapshot }
        }
        switch providerID {
        case "claude": return claude
        case "codex":  return codex
        default:       return nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case claude, codex, usage, lastChecked
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.claude = try c.decodeIfPresent(UsageData.self, forKey: .claude)
        self.codex = try c.decodeIfPresent(UsageData.self, forKey: .codex)
        self.usage = try c.decodeIfPresent([String: UsageData].self, forKey: .usage)
        self.lastChecked = try c.decode(Date.self, forKey: .lastChecked)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(claude, forKey: .claude)
        try c.encodeIfPresent(codex, forKey: .codex)
        try c.encodeIfPresent(usage, forKey: .usage)
        try c.encode(lastChecked, forKey: .lastChecked)
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
    /// v0.7.2 (wire v8 additive): when set + `suggestedAgent == .codex`,
    /// the Mac daemon dispatches this draft to
    /// `CodexSDKManager.runResume(threadId:prompt:)` instead of the
    /// default empty-state-composer pre-fill flow. Enables iOS→Mac
    /// thread continuation: iPhone holds a `Thread.id` from a prior
    /// `codex.startThread()` / `resumeThread()`, taps "Open on Mac",
    /// Mac resumes that thread + runs the prompt to completion.
    /// `decodeIfPresent` — v7 Macs ignore this field cleanly.
    public let codexThreadId: String?

    public init(
        text: String,
        repoKey: String? = nil,
        suggestedAgent: AgentKind? = nil,
        suggestedModel: String? = nil,
        suggestedEffort: ReasoningEffort? = nil,
        codexThreadId: String? = nil,
        createdAt: Date = Date()
    ) {
        self.text = text
        self.repoKey = repoKey
        self.suggestedAgent = suggestedAgent
        self.suggestedModel = suggestedModel
        self.suggestedEffort = suggestedEffort
        self.codexThreadId = codexThreadId
        self.createdAt = createdAt
    }

    // MARK: - Codable (codexThreadId is decodeIfPresent for wire v7 back-compat)

    enum CodingKeys: String, CodingKey {
        case text, repoKey, suggestedAgent, suggestedModel, suggestedEffort, codexThreadId, createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.text = try c.decode(String.self, forKey: .text)
        self.repoKey = try c.decodeIfPresent(String.self, forKey: .repoKey)
        self.suggestedAgent = try c.decodeIfPresent(AgentKind.self, forKey: .suggestedAgent)
        self.suggestedModel = try c.decodeIfPresent(String.self, forKey: .suggestedModel)
        self.suggestedEffort = try c.decodeIfPresent(ReasoningEffort.self, forKey: .suggestedEffort)
        // v0.7.2: codexThreadId is wire v8 additive. v7 iOS clients
        // never populate it; v8 daemons ignore absent field.
        self.codexThreadId = try c.decodeIfPresent(String.self, forKey: .codexThreadId)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(text, forKey: .text)
        try c.encodeIfPresent(repoKey, forKey: .repoKey)
        try c.encodeIfPresent(suggestedAgent, forKey: .suggestedAgent)
        try c.encodeIfPresent(suggestedModel, forKey: .suggestedModel)
        try c.encodeIfPresent(suggestedEffort, forKey: .suggestedEffort)
        try c.encodeIfPresent(codexThreadId, forKey: .codexThreadId)
        try c.encode(createdAt, forKey: .createdAt)
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

// MARK: - Antigravity Plan wire DTOs (v7)

/// Snapshot of a brain dir's task + steps + annotations + usage, served
/// by `GET /sessions/:id/antigravity-plan` and pushed via the
/// `antigravity-plan-subscribe` WS op (wire v7+).
///
/// Decoding is forward-compatible: older Macs (v6) don't serve this
/// shape, so iOS gates the Plan tab on `supportsAntigravityPlan(...)`.
/// Newer Macs may add fields — iOS uses decodeIfPresent so partial
/// envelopes still parse cleanly.
public struct AntigravityPlanSnapshot: Codable, Equatable, Sendable {
    /// Session id this snapshot is for.
    public let sessionId: UUID
    /// Brain UUID (Antigravity's identifier — same as `brain/<uuid>/`
    /// and `conversations/<uuid>.pb`).
    public let brainUUID: String
    /// `task.md` headline (first non-blank line, hash-stripped). Empty
    /// when the brain dir is in the `.awaitingFirstTurn` state.
    public let taskHeadline: String
    /// `task.md` body — everything after the headline, plaintext
    /// markdown. Empty when no body or awaitingFirstTurn.
    public let taskBody: String
    /// Parsed checklist from `implementation_plan.md`. Empty when no
    /// plan or awaitingFirstTurn.
    public let planSteps: [WirePlanStep]
    /// Per-brain annotations (`annotations/*.pbtxt` body).
    public let annotations: [WireBrainArtifact]
    /// Coarse token usage. Nil when the data source can't determine
    /// (Disk mode + encrypted conversation file → nil; SDK mode → real
    /// per-message totals).
    public let totalUsage: WireTokenUsage?
    /// Last-modified timestamp across the brain dir.
    public let lastUpdated: Date
    /// Currently selected model display name. Nil when unknown.
    public let model: String?
    /// True when SDK mode is active on the daemon (per Settings toggle).
    /// Nil-coalesces to false on older wire versions.
    public let sdkModeActive: Bool?
    /// Awaiting-first-turn flag. When true, the brain dir exists but
    /// task.md/implementation_plan.md haven't been written yet; the UI
    /// renders the spinner state. Eng review 2A fix surfaced via the
    /// wire so iOS doesn't have to re-derive it from empty content.
    public let awaitingFirstTurn: Bool

    public init(
        sessionId: UUID,
        brainUUID: String,
        taskHeadline: String,
        taskBody: String,
        planSteps: [WirePlanStep],
        annotations: [WireBrainArtifact],
        totalUsage: WireTokenUsage?,
        lastUpdated: Date,
        model: String?,
        sdkModeActive: Bool?,
        awaitingFirstTurn: Bool
    ) {
        self.sessionId = sessionId
        self.brainUUID = brainUUID
        self.taskHeadline = taskHeadline
        self.taskBody = taskBody
        self.planSteps = planSteps
        self.annotations = annotations
        self.totalUsage = totalUsage
        self.lastUpdated = lastUpdated
        self.model = model
        self.sdkModeActive = sdkModeActive
        self.awaitingFirstTurn = awaitingFirstTurn
    }
}

/// Wire DTO for one step in `implementation_plan.md`. Named `WirePlanStep`
/// to avoid collision with the existing `PlanStep` (consumed by the v1
/// PlanTrackerPane). Carries the same data as `BrainPlanStep` (Commit 3)
/// but flat — sub-steps come through as separate entries with `depth > 0`
/// instead of nested arrays. Flat shape simplifies JSON encoding +
/// iOS SwiftUI rendering.
public struct WirePlanStep: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public let isComplete: Bool
    public let depth: Int

    public init(id: String, label: String, isComplete: Bool, depth: Int) {
        self.id = id
        self.label = label
        self.isComplete = isComplete
        self.depth = depth
    }
}

/// Wire DTO for an annotation (`annotations/*.pbtxt`). Surfaces the
/// filename + plaintext body — Antigravity's annotation schema isn't
/// fully reverse-engineered, but the body is text-proto so the Plan
/// pane can render it as a monospace block.
public struct WireBrainArtifact: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let filename: String
    public let body: String

    public init(id: String, filename: String, body: String) {
        self.id = id
        self.filename = filename
        self.body = body
    }
}

/// Wire DTO for token usage. Optional fields because Disk mode can't
/// extract them from encrypted conversation files — see the deviation
/// note in the plan file's "Deviations during implementation" section.
/// SDK mode populates all four counters; Disk mode populates only the
/// estimate.
public struct WireTokenUsage: Codable, Equatable, Sendable {
    /// Total token count (sum of prompt + candidate + thoughts + cached).
    /// Disk mode: the `~estimated` value from `ConversationProtoParser`.
    /// SDK mode: real value from `agent.conversation.total_usage`.
    public let total: Int
    /// Prompt (input) tokens. Nil in Disk mode (encryption).
    public let prompt: Int?
    /// Candidate (output) tokens. Nil in Disk mode.
    public let candidate: Int?
    /// Thoughts (reasoning) tokens. Nil in Disk mode.
    public let thoughts: Int?
    /// Cached tokens (from cache hits). Nil in Disk mode.
    public let cached: Int?
    /// True when the value is the Disk mode coarse estimate; UI renders
    /// a `~` provisional marker when true. Nil when unknown — treat as
    /// false (exact value).
    public let isEstimate: Bool?

    public init(
        total: Int,
        prompt: Int? = nil,
        candidate: Int? = nil,
        thoughts: Int? = nil,
        cached: Int? = nil,
        isEstimate: Bool? = nil
    ) {
        self.total = total
        self.prompt = prompt
        self.candidate = candidate
        self.thoughts = thoughts
        self.cached = cached
        self.isEstimate = isEstimate
    }
}

// MARK: - Chat tab (v0.8 — wire v9)

/// `POST /chat-sessions` request body. Spawns a new chat session
/// (`AgentSession.kind == .chat`) with an empty per-session chat-cwd.
/// `effort` is optional and only honored by Claude/Codex; gemini chat
/// returns 501 in v0.8 until the Antigravity (agy) replacement lands
/// in v0.9. `codexChatBackend` overrides the server-side default per
/// session; nil means "use the pairing default" (RE1 SDK).
public struct CreateChatSessionRequest: Codable, Sendable {
    public let provider: AgentKind
    public let model: String?
    public let effort: ReasoningEffort?
    public let codexChatBackend: CodexChatBackend?
    /// v14 (Chat V2): when true, the daemon spawns the chat with deep-
    /// research argv (Claude: `--allowedTools WebSearch,WebFetch,...` +
    /// `--append-system-prompt deep-research-prompt.txt` + `--effort max`).
    /// For Codex SDK chats, the relay payload gets `tools: ["web_search"]`
    /// and `modelReasoningEffort: "xhigh"`. For Gemini, the agentapi
    /// session-init picks `gemini-3-pro` + deep-research system
    /// instruction. Defaults to false on older clients (decodeIfPresent).
    public let deepResearch: Bool

    public init(
        provider: AgentKind,
        model: String? = nil,
        effort: ReasoningEffort? = nil,
        codexChatBackend: CodexChatBackend? = nil,
        deepResearch: Bool = false
    ) {
        self.provider = provider
        self.model = model
        self.effort = effort
        self.codexChatBackend = codexChatBackend
        self.deepResearch = deepResearch
    }

    private enum CodingKeys: String, CodingKey {
        case provider, model, effort, codexChatBackend, deepResearch
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.provider = try c.decode(AgentKind.self, forKey: .provider)
        self.model = try c.decodeIfPresent(String.self, forKey: .model)
        self.effort = try c.decodeIfPresent(ReasoningEffort.self, forKey: .effort)
        self.codexChatBackend = try c.decodeIfPresent(CodexChatBackend.self, forKey: .codexChatBackend)
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
    public let codexChatBackend: CodexChatBackend?
    /// v14 (Chat V2): per-slot Deep Research toggle. Each broadcast pane
    /// can independently run with deep-research argv. Defaults to false
    /// on older clients (decodeIfPresent).
    public let deepResearch: Bool

    public init(
        provider: AgentKind,
        model: String? = nil,
        codexChatBackend: CodexChatBackend? = nil,
        deepResearch: Bool = false
    ) {
        self.provider = provider
        self.model = model
        self.codexChatBackend = codexChatBackend
        self.deepResearch = deepResearch
    }

    private enum CodingKeys: String, CodingKey {
        case provider, model, codexChatBackend, deepResearch
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.provider = try c.decode(AgentKind.self, forKey: .provider)
        self.model = try c.decodeIfPresent(String.self, forKey: .model)
        self.codexChatBackend = try c.decodeIfPresent(CodexChatBackend.self, forKey: .codexChatBackend)
        self.deepResearch = try c.decodeIfPresent(Bool.self, forKey: .deepResearch) ?? false
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

    public init(groupId: UUID, updateCounter: Int, children: [FrontierChild]) {
        self.groupId = groupId
        self.updateCounter = updateCounter
        self.children = children
    }
}

/// One child entry inside a `FrontierGroupSnapshot`.
public struct FrontierChild: Codable, Sendable {
    public let childIndex: Int
    public let sessionId: UUID
    public let modelSlug: String
    /// Nil when the child failed to spawn (D10 partial Frontier).
    public let snapshot: WireChatSnapshot?
    public let status: FrontierChildStatus

    public init(
        childIndex: Int,
        sessionId: UUID,
        modelSlug: String,
        snapshot: WireChatSnapshot? = nil,
        status: FrontierChildStatus
    ) {
        self.childIndex = childIndex
        self.sessionId = sessionId
        self.modelSlug = modelSlug
        self.snapshot = snapshot
        self.status = status
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
/// observer state. Codex has two sub-rows (sdk + cli); Gemini is
/// hardcoded `available: false, reason: "v0.9"` until Antigravity
/// (agy) ships.
public struct ChatProvidersResponse: Codable, Sendable {
    public let providers: [ChatProviderEntry]

    public init(providers: [ChatProviderEntry]) {
        self.providers = providers
    }
}

/// One row in `ChatProvidersResponse`. For Codex, two entries (one per
/// backend) appear; for Claude/Gemini, one entry each.
public struct ChatProviderEntry: Codable, Sendable {
    public let provider: AgentKind
    /// For Codex: the backend variant this row describes. Nil for
    /// non-Codex.
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
    /// Optional reason string for `available: false` rows. E.g.
    /// "v0.9" (Gemini), "Re-authenticate via `codex login`",
    /// "Codex SDK not provisioned — Toggle in Settings".
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

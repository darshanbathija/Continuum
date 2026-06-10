import Foundation

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
        case .bypass:      return "Full access"
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
    /// When set, this entry belongs to a user-configured custom provider.
    public let customProviderId: String?

    public init(
        id: String,
        provider: AgentKind,
        displayName: String,
        cliAlias: String? = nil,
        supportsThinking: Bool = true,
        supportsEffort: Bool = true,
        contextWindow: Int? = nil,
        recommendedFor: String? = nil,
        badge: String? = nil,
        customProviderId: String? = nil
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
        self.customProviderId = customProviderId
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
    /// OpenCode is a runtime/provider adapter, not a single model vendor.
    /// Entries here represent Clawdmeter-visible choices while the exact
    /// underlying provider/model identity is persisted on
    /// `SessionRuntimeBinding.providerModelId`.
    public let opencode: [ModelCatalogEntry]
    /// Cursor models are account-visible and should normally be replaced by
    /// a live probe from `cursor-agent --list-models` / `agent models`.
    /// The bundled fallback intentionally contains only Auto so we do not
    /// claim access to models the user's Cursor account may not expose.
    public let cursor: [ModelCatalogEntry]
    /// xAI Grok models (wire v26). ACP agents advertise models at `initialize`,
    /// so this is the bundled fallback used until a live list is fetched.
    public let grok: [ModelCatalogEntry]
    /// Optional provider-enable envelope. Missing means legacy all-provider
    /// behavior for older Macs/iOS builds; an empty array is an explicit
    /// zero-provider state.
    public let enabledProviderIDs: [String]?
    /// User-configured OpenAI/Anthropic-compatible providers (wire v28).
    /// Enablement lives on each summary's `enabled` flag — not filtered by
    /// `enabledProviderIDs`.
    public let customProviders: [CustomProviderWireSummary]
    public let updatedAt: Date

    public init(
        claude: [ModelCatalogEntry],
        codex: [ModelCatalogEntry],
        gemini: [ModelCatalogEntry] = [],
        opencode: [ModelCatalogEntry] = [],
        cursor: [ModelCatalogEntry] = [],
        grok: [ModelCatalogEntry] = [],
        enabledProviderIDs: [String]? = nil,
        customProviders: [CustomProviderWireSummary] = [],
        updatedAt: Date
    ) {
        self.claude = claude
        self.codex = codex
        self.gemini = gemini
        self.opencode = opencode
        self.cursor = cursor
        self.grok = grok
        self.enabledProviderIDs = enabledProviderIDs
        self.customProviders = customProviders
        self.updatedAt = updatedAt
    }

    /// Bundled default catalog (latest first):
    /// Fable 5 1M / Fable 5 / Opus 4.8 1M / Opus 4.8 / Opus 4.7 1M / Opus 4.7 / Opus 4.6 1M / Sonnet 4.6 / Haiku 4.5 +
    /// GPT-5.5 / GPT-5.4 / GPT-5.3-Codex-Spark / GPT-5.3-Codex / GPT-5.2-Codex.
    /// Gemini entries reflect Antigravity's 2026-05-19 v1internal:fetchAvailableModels
    /// response (Gemini 3.1 Pro High/Low + Gemini 3 Flash).
    public static let bundled = ModelCatalog(
        claude: [
            // Claude Fable 5 (2026-06): Anthropic's most capable widely
            // released model. The API serves a 1M window natively, but
            // Claude Code keeps its long-context mode behind the same
            // "[1m]" tag as the Opus family, so the catalog mirrors the
            // -1m/base pair convention (AgentSpawner translates the
            // "-1m" suffix to the CLI's bracket form at spawn).
            ModelCatalogEntry(id: "claude-fable-5-1m",         provider: .claude, displayName: "Fable 5 (1M)",    cliAlias: nil,      supportsThinking: true,  supportsEffort: true,  contextWindow: 1_000_000, recommendedFor: "Hardest tasks",  badge: "1M"),
            ModelCatalogEntry(id: "claude-fable-5",            provider: .claude, displayName: "Fable 5",         cliAlias: nil,      supportsThinking: true,  supportsEffort: true,  contextWindow: 200_000,   recommendedFor: "Frontier work",  badge: "New"),
            ModelCatalogEntry(id: "claude-opus-4-8-1m",        provider: .claude, displayName: "Opus 4.8 (1M)",   cliAlias: nil,      supportsThinking: true,  supportsEffort: true,  contextWindow: 1_000_000, recommendedFor: "Long tasks",     badge: "1M"),
            ModelCatalogEntry(id: "claude-opus-4-8",           provider: .claude, displayName: "Opus 4.8",        cliAlias: "opus",   supportsThinking: true,  supportsEffort: true,  contextWindow: 200_000,   recommendedFor: "Most work",      badge: nil),
            ModelCatalogEntry(id: "claude-opus-4-7-1m",        provider: .claude, displayName: "Opus 4.7 (1M)",   cliAlias: nil,      supportsThinking: true,  supportsEffort: true,  contextWindow: 1_000_000, recommendedFor: nil,              badge: "1M"),
            ModelCatalogEntry(id: "claude-opus-4-7",           provider: .claude, displayName: "Opus 4.7",        cliAlias: nil,      supportsThinking: true,  supportsEffort: true,  contextWindow: 200_000,   recommendedFor: nil,              badge: nil),
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
        opencode: [
            ModelCatalogEntry(id: "openai/gpt-5.5", provider: .opencode, displayName: "OpenRouter · GPT-5.5", cliAlias: nil, supportsThinking: true, supportsEffort: true, contextWindow: nil, recommendedFor: "Most work", badge: "BYOK"),
            ModelCatalogEntry(id: "anthropic/claude-opus-4.7", provider: .opencode, displayName: "OpenRouter · Claude Opus 4.7", cliAlias: nil, supportsThinking: true, supportsEffort: true, contextWindow: 200_000, recommendedFor: "Deep reasoning", badge: nil),
            ModelCatalogEntry(id: "anthropic/claude-sonnet-4.6", provider: .opencode, displayName: "OpenRouter · Claude Sonnet 4.6", cliAlias: nil, supportsThinking: true, supportsEffort: true, contextWindow: 200_000, recommendedFor: "Plan mode", badge: nil),
            ModelCatalogEntry(id: "google/gemini-3-pro", provider: .opencode, displayName: "OpenRouter · Gemini 3 Pro", cliAlias: nil, supportsThinking: true, supportsEffort: false, contextWindow: 2_000_000, recommendedFor: "Deep reasoning", badge: "Pro"),
            ModelCatalogEntry(id: "opencode-default", provider: .opencode, displayName: "OpenCode default", cliAlias: nil, supportsThinking: true, supportsEffort: false, contextWindow: nil, recommendedFor: "BYOK provider", badge: "Default"),
        ],
        cursor: [
            ModelCatalogEntry(id: CursorModelCatalog.autoModelId, provider: .cursor, displayName: "Cursor default / Auto", cliAlias: nil, supportsThinking: true, supportsEffort: false, contextWindow: nil, recommendedFor: "Cursor account default", badge: "Auto"),
        ],
        grok: [
            // Live-probed from `grok models` (cmux Grok Build 0.2.16, 2026-06-03).
            // Driven headless (GrokHeadlessDriver) — no ACP. These ids are what the
            // grok CLI's `--model` flag accepts for this login.
            ModelCatalogEntry(id: "grok-build", provider: .grok, displayName: "Grok Build", cliAlias: nil, supportsThinking: true, supportsEffort: true, contextWindow: 500_000, recommendedFor: "Advanced coding", badge: "Default"),
            ModelCatalogEntry(id: "grok-composer-2.5-fast", provider: .grok, displayName: "Grok Composer 2.5 Fast", cliAlias: nil, supportsThinking: false, supportsEffort: true, contextWindow: 256_000, recommendedFor: "Fast iteration", badge: "Fast"),
        ],
        updatedAt: Date(timeIntervalSince1970: 1747353600) // 2026-05-15
    )

    /// Resolve a model id to a catalog entry across all providers.
    public func entry(forId id: String) -> ModelCatalogEntry? {
        if let match = entry(forId: id, customProviderId: nil) {
            return match
        }
        return customProviders
            .flatMap(\.entries)
            .first { $0.id == id || $0.cliAlias == id }
    }

    /// Collision-safe lookup when a custom endpoint may serve a model id
    /// that also exists in the bundled catalog (e.g. `gpt-5.5`).
    public func entry(forId id: String, customProviderId: String?) -> ModelCatalogEntry? {
        if let customProviderId {
            if let summary = customProviders.first(where: { $0.id == customProviderId }),
               let match = summary.entries.first(where: { $0.id == id || $0.cliAlias == id }) {
                return match
            }
            return nil
        }
        return AgentKind.allCases.lazy
            .flatMap { entries(for: $0) }
            .first { $0.id == id || $0.cliAlias == id }
    }

    /// Provider-indexed catalog used by Code V2 pickers. The legacy arrays
    /// stay on the wire for back-compat; this accessor is the new durable
    /// shape clients should prefer.
    public var byProvider: [String: [ModelCatalogEntry]] {
        [
            AgentKind.claude.rawValue: entries(for: .claude),
            AgentKind.codex.rawValue: entries(for: .codex),
            AgentKind.gemini.rawValue: entries(for: .gemini),
            AgentKind.opencode.rawValue: entries(for: .opencode),
            AgentKind.cursor.rawValue: entries(for: .cursor),
            AgentKind.grok.rawValue: entries(for: .grok),
        ]
    }

    public func entries(for provider: AgentKind) -> [ModelCatalogEntry] {
        guard provider != .unknown else { return [] }
        if let enabledProviderIDs {
            let enabled = Set(enabledProviderIDs.map { ProviderRegistry.rootProviderID(for: $0) })
            guard enabled.contains(ProviderRegistry.rootProviderID(for: provider.rawValue)) else {
                return []
            }
        }
        switch provider {
        case .claude: return claude
        case .codex: return codex
        case .gemini: return gemini
        case .opencode: return opencode
        case .cursor: return cursor
        case .grok: return grok
        case .unknown: return []
        }
    }

    public func replacingCursor(_ cursor: [ModelCatalogEntry]) -> ModelCatalog {
        ModelCatalog(
            claude: claude,
            codex: codex,
            gemini: gemini,
            opencode: opencode,
            cursor: cursor,
            grok: grok,
            enabledProviderIDs: enabledProviderIDs,
            customProviders: customProviders,
            updatedAt: Date()
        )
    }

    public func replacingOpenRouter(_ opencode: [ModelCatalogEntry]) -> ModelCatalog {
        ModelCatalog(
            claude: claude,
            codex: codex,
            gemini: gemini,
            opencode: opencode,
            cursor: cursor,
            grok: grok,
            enabledProviderIDs: enabledProviderIDs,
            customProviders: customProviders,
            updatedAt: Date()
        )
    }

    public func filteredToEnabledProviders(for capability: ProviderCapability = .code) -> ModelCatalog {
        filtered(toEnabledProviderIDs: ProviderEnablement.enabledProviderIDs(for: capability))
    }

    public func filtered(toEnabledProviderIDs enabledIDs: [String]) -> ModelCatalog {
        let enabled = Set(enabledIDs.map { ProviderRegistry.rootProviderID(for: $0) })
        func allowed(_ provider: AgentKind) -> Bool {
            enabled.contains(ProviderRegistry.rootProviderID(for: provider.rawValue))
        }
        return ModelCatalog(
            claude: allowed(.claude) ? claude : [],
            codex: allowed(.codex) ? codex : [],
            gemini: allowed(.gemini) ? gemini : [],
            opencode: allowed(.opencode) ? opencode : [],
            cursor: allowed(.cursor) ? cursor : [],
            grok: allowed(.grok) ? grok : [],
            enabledProviderIDs: enabledIDs,
            customProviders: customProviders,
            updatedAt: updatedAt
        )
    }

    // MARK: - Codable

    /// Custom decoder so v5 payloads (no `gemini` field) decode cleanly.
    /// Mirror of TokenTotals' X2 fix at the catalog level — synthesized
    /// Codable throws on missing keys; decodeIfPresent + default returns
    /// an empty Gemini array.
    private enum CodingKeys: String, CodingKey {
        case claude, codex, gemini, opencode, cursor, grok, enabledProviderIDs, customProviders, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.claude = try c.decode([ModelCatalogEntry].self, forKey: .claude)
        self.codex = try c.decode([ModelCatalogEntry].self, forKey: .codex)
        self.gemini = try c.decodeIfPresent([ModelCatalogEntry].self, forKey: .gemini) ?? []
        self.opencode = try c.decodeIfPresent([ModelCatalogEntry].self, forKey: .opencode) ?? []
        self.cursor = try c.decodeIfPresent([ModelCatalogEntry].self, forKey: .cursor) ?? []
        self.grok = try c.decodeIfPresent([ModelCatalogEntry].self, forKey: .grok) ?? []
        self.enabledProviderIDs = try c.decodeIfPresent([String].self, forKey: .enabledProviderIDs)
        self.customProviders = try c.decodeIfPresent([CustomProviderWireSummary].self, forKey: .customProviders) ?? []
        self.updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(claude, forKey: .claude)
        try c.encode(codex, forKey: .codex)
        try c.encode(gemini, forKey: .gemini)
        try c.encode(opencode, forKey: .opencode)
        try c.encode(cursor, forKey: .cursor)
        try c.encode(grok, forKey: .grok)
        try c.encodeIfPresent(enabledProviderIDs, forKey: .enabledProviderIDs)
        try c.encode(customProviders, forKey: .customProviders)
        try c.encode(updatedAt, forKey: .updatedAt)
    }
}

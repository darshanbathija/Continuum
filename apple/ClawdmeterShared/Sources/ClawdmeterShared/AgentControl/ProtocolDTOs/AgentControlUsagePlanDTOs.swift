import Foundation

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
    /// Optional provider-enable envelope. Missing means legacy all-provider
    /// behavior for older Mac/iOS payloads; an empty array is explicit no
    /// enabled providers.
    public let enabledProviderIDs: [String]?
    /// Server-side wall-clock when the snapshot was assembled. The
    /// iPhone uses this to age the gauges ("Last checked X ago") so
    /// the user knows when the Mac last actually polled the providers.
    public let lastChecked: Date

    public init(
        claude: UsageData?,
        codex: UsageData?,
        usage: [String: UsageData]? = nil,
        enabledProviderIDs: [String]? = nil,
        lastChecked: Date
    ) {
        self.claude = claude
        self.codex = codex
        self.usage = usage
        self.enabledProviderIDs = enabledProviderIDs
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
        if let enabledProviderIDs {
            let enabled = Set(enabledProviderIDs.map { ProviderRegistry.rootProviderID(for: $0) })
            guard enabled.contains(ProviderRegistry.rootProviderID(for: providerID)) else {
                return nil
            }
        }
        if let dict = usage {
            // Direct hit.
            if let snapshot = dict[providerID] { return snapshot }
            // v10 dual-key bridge. Gemini provider data may be under
            // either "gemini" (v6-v9 servers) or "antigravity" (v10+).
            // Both directions resolve cleanly.
            if providerID == "gemini",      let snapshot = dict["antigravity"] { return snapshot }
            if providerID == "antigravity", let snapshot = dict["gemini"]      { return snapshot }
            // F3-wire (v20) per-instance dual-key bridge. v20+ servers
            // populate `usage[<wireId>]` for every configured instance
            // (e.g. `claude/__primary__`, `claude/personal`); v19
            // clients ask for the bare kind (`"claude"`) and still
            // resolve to the primary instance via the wireId lookup.
            // Symmetric: a v20 client asking for `"claude/__primary__"`
            // reading a v19 server's dict (which only has `"claude"`)
            // resolves through the primary suffix-strip.
            let primarySuffix = "/\(ProviderInstanceId.primaryName)"
            if providerID.hasSuffix(primarySuffix) {
                let kindOnly = String(providerID.dropLast(primarySuffix.count))
                if let snapshot = dict[kindOnly] { return snapshot }
            }
            if !providerID.contains("/") {
                if let snapshot = dict["\(providerID)\(primarySuffix)"] { return snapshot }
            }
        }
        // Strip any per-instance suffix before the legacy-field fallback —
        // legacy `claude`/`codex` fields only ever carry the primary
        // instance's snapshot.
        let kindOnly: String = {
            if let slash = providerID.firstIndex(of: "/") {
                return String(providerID[..<slash])
            }
            return providerID
        }()
        switch kindOnly {
        case "claude": return claude
        case "codex":  return codex
        default:       return nil
        }
    }

    /// F3-wire (v20) per-instance read. Resolves to the dict entry keyed
    /// by `instance.wireId`, falling back through the
    /// `usageData(for:)` ladder for back-compat. Primary instances
    /// resolve to the legacy `claude` / `codex` fields when a v19
    /// server populated only those.
    public func usageData(for instance: ProviderInstanceId) -> UsageData? {
        if let snapshot = usageData(for: instance.wireId) { return snapshot }
        if instance.isPrimary {
            return usageData(for: instance.kind.rawValue)
        }
        return nil
    }

    /// Multi-account (wire v28): one entry per SECONDARY account key
    /// (`claude/work`) in the `usage` dict. Primaries stay on the legacy
    /// kind keys and never appear here. Sorted by wireId for stable UI.
    public struct SecondaryInstanceUsage: Sendable, Equatable, Identifiable {
        public let wireId: String
        public let kind: String
        public let name: String
        public let usage: UsageData
        public var id: String { wireId }
    }

    public func secondaryInstanceUsage() -> [SecondaryInstanceUsage] {
        guard let usage else { return [] }
        return usage.compactMap { (key, value) -> SecondaryInstanceUsage? in
            guard let slash = key.firstIndex(of: "/") else { return nil }
            let name = String(key[key.index(after: slash)...])
            guard name != ProviderInstanceId.primaryName, !name.isEmpty else { return nil }
            return SecondaryInstanceUsage(
                wireId: key,
                kind: String(key[..<slash]),
                name: name,
                usage: value
            )
        }
        .sorted { $0.wireId < $1.wireId }
    }

    private enum CodingKeys: String, CodingKey {
        case claude, codex, usage, enabledProviderIDs, lastChecked
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.claude = try c.decodeIfPresent(UsageData.self, forKey: .claude)
        self.codex = try c.decodeIfPresent(UsageData.self, forKey: .codex)
        self.usage = try c.decodeIfPresent([String: UsageData].self, forKey: .usage)
        self.enabledProviderIDs = try c.decodeIfPresent([String].self, forKey: .enabledProviderIDs)
        self.lastChecked = try c.decode(Date.self, forKey: .lastChecked)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(claude, forKey: .claude)
        try c.encodeIfPresent(codex, forKey: .codex)
        try c.encodeIfPresent(usage, forKey: .usage)
        try c.encodeIfPresent(enabledProviderIDs, forKey: .enabledProviderIDs)
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

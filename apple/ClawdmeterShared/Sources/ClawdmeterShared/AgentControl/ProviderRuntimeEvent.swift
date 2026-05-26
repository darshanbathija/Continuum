import Foundation

/// Canonical provider runtime event — the lossless, provider-agnostic shape
/// that **every** provider adapter (Claude / Codex / OpenCode / Cursor /
/// Antigravity) emits and the orchestration layer consumes.
///
/// **Why canonical?** Today `AgentControlServer.swift` (~7392 lines)
/// switches on `agentKind` at every entry point and re-derives provider-
/// specific event shapes per call site. F1 (strangler-fig per D23) inverts
/// that: each provider adapter emits `ProviderRuntimeEvent` values; the
/// orchestration layer + chat store + analytics consume the canonical
/// shape; AgentControlServer becomes a thin router.
///
/// **Lossless raw payload retention** (codex eng-review #8 incorporated):
/// every event carries `rawProviderPayload` — the bytes the provider
/// adapter received, opaquely retained for debugging + replay + future
/// schema evolution. Canonical fields hold the **normalized** view; raw
/// holds the **exact** source. Never lose information by flattening.
///
/// **Provider-specific extensions**: fields that genuinely don't fit the
/// canonical shape (e.g. Antigravity's `step_payload` protobuf field
/// numbers, Codex's reasoning effort levels, Claude's `cache_creation`
/// token type) live under `providerExtensions` keyed by adapter. They
/// survive round-trips but aren't part of the canonical contract.
///
/// **Plan reference**: F1 foundation (Phase 1; D23 strangler-fig split).
/// F1a (Claude adapter), F1b (Codex), F1c (OpenCode), F1d (Cursor), F1e
/// (Antigravity) all consume this type. See
/// `.claude/plans/study-this-codebase-crystalline-shore.md`.
///
/// **Mirror reference**: t3code's
/// [`ClaudeAdapter.ts`](https://github.com/pingdotgg/t3code/blob/main/apps/server/src/provider/Layers/ClaudeAdapter.ts)
/// + `providerRuntime.ts` schemas. We mirror the SHAPE (kind + payload +
/// stream-position + raw retention) but stay native Swift; no Effect, no
/// Schema runtime, no TypeScript dependency.
public struct ProviderRuntimeEvent: Sendable, Equatable, Codable {

    // MARK: - Header

    /// Stable identifier for this event within its session. Adapter
    /// assigns; orchestration uses for replay/dedupe.
    public let id: String

    /// Provider kind that emitted the event. Matches the existing
    /// `AgentKind` enum used throughout Clawdmeter today.
    public let providerKind: AgentKind

    /// Per-instance identifier (introduced in F3 — split provider KIND
    /// from configured INSTANCE so claude_personal + claude_work coexist).
    /// Optional today; required once F3 lands.
    public let providerInstanceId: String?

    /// Session this event belongs to. Mirrors Clawdmeter's existing
    /// `AgentSession.id` shape (free-form string, daemon-generated).
    public let sessionId: String

    /// Monotonic per-session sequence number. Adapter increments; the
    /// orchestration command store (F2) uses this for replay ordering.
    public let sequenceNumber: UInt64

    /// Adapter's emit timestamp.
    public let emittedAt: Date

    // MARK: - Payload

    /// The discriminated payload. New cases are added as providers grow.
    /// `.unknown(name:)` is for **adapter-emit-side** use: when an
    /// adapter receives a provider event it has no canonical case for, it
    /// emits `.unknown(name:)` with `rawProviderPayload` set so
    /// downstream consumers can still observe + replay. Wire decode of an
    /// unknown payload kind (a new canonical case a vN-1 client doesn't
    /// know about) throws — clients that need forward-compat at the wire
    /// layer must update their decoder.
    public let payload: Payload

    // MARK: - Raw retention (codex #8)

    /// The bytes the adapter received from its provider, untouched.
    /// Diagnostic / replay / future schema evolution. NEVER consult this
    /// for live decision-making — that's what `payload` is for.
    public let rawProviderPayload: Data?

    /// Provider-specific extension fields that don't fit the canonical
    /// shape. Keyed by short adapter id ("claude", "codex", "opencode",
    /// "cursor", "antigravity"). Surviving fields are e.g. Antigravity's
    /// `step_payload` field numbers, Claude's `cache_creation` token
    /// type, Codex's `reasoning_effort`. Round-trip-safe via Codable.
    public let providerExtensions: [String: ExtensionField]?

    public init(
        id: String,
        providerKind: AgentKind,
        providerInstanceId: String? = nil,
        sessionId: String,
        sequenceNumber: UInt64,
        emittedAt: Date,
        payload: Payload,
        rawProviderPayload: Data? = nil,
        providerExtensions: [String: ExtensionField]? = nil
    ) {
        self.id = id
        self.providerKind = providerKind
        self.providerInstanceId = providerInstanceId
        self.sessionId = sessionId
        self.sequenceNumber = sequenceNumber
        self.emittedAt = emittedAt
        self.payload = payload
        self.rawProviderPayload = rawProviderPayload
        self.providerExtensions = providerExtensions
    }

    // MARK: - Payload variants

    public enum Payload: Sendable, Equatable, Codable {
        /// Provider session started. `model` is the resolved model
        /// string the provider settled on (may differ from what the user
        /// asked for if the model was substituted, e.g. effort downgrade).
        case sessionStarted(model: String, settings: [String: String])

        /// Provider session ended. Reason is provider-specific text;
        /// canonical doesn't try to normalize "user cancelled" vs "quota
        /// exceeded" — that's analytics-layer work.
        case sessionEnded(reason: String?)

        /// User message dispatched to the provider.
        case userMessage(text: String, attachmentRefs: [String])

        /// Assistant streaming token delta. `index` is the token's offset
        /// within the response, used by the isolated-streaming-message
        /// view (A9) to thread tokens into the active bubble.
        case assistantTokenDelta(text: String, index: Int)

        /// Assistant message completed. `text` is the full text for the
        /// turn (canonical reconstruction; the adapter has already joined
        /// the deltas). Token counts are the provider-reported tallies.
        case assistantMessageCompleted(text: String, tokensIn: Int, tokensOut: Int)

        /// Tool use invocation by the assistant.
        case toolUse(name: String, parameters: [String: String], invocationId: String)

        /// Tool use result returned to the assistant.
        case toolResult(invocationId: String, success: Bool, text: String)

        /// Plan / approval request awaiting user response.
        case planRequested(planText: String, planId: String)

        /// User responded to a plan request.
        case planApprovalResponded(planId: String, approved: Bool, comment: String?)

        /// Error surfaced by the provider. Canonical normalizes to (code,
        /// message). Adapters MUST set `rawProviderPayload` so debugging
        /// can recover the original error envelope.
        case providerError(code: String, message: String)

        /// Adapter-emit-side catch-all. Adapters emit this when the
        /// provider surfaces a kind we haven't added a canonical case
        /// for. The `name` is the raw kind string; full data lives in
        /// `rawProviderPayload`. Downstream consumers can still observe
        /// + replay the event. NOTE: this case does **not** make the
        /// wire decoder forward-compat — a wire payload tagged with a
        /// canonical case the local decoder doesn't know throws a
        /// `DecodingError` (see `ProviderRuntimeEventTests`).
        case unknown(name: String)
    }

    // MARK: - Extension fields

    /// Type-erased Codable payload for provider-specific extension data.
    /// We keep this small + explicit (string + int + double + bool +
    /// optional nesting) rather than dragging in `AnyCodable` — the
    /// adapters know exactly what they need to plumb here.
    ///
    /// **Wire encoding** uses an explicit `{"_type": <tag>, "value": <v>}`
    /// envelope so every variant round-trips losslessly. A scalar-heuristic
    /// decoder (try-String-then-Int-then-…) loses information: `Data`
    /// encoded as Base64 string would decode back as `.string`, and a
    /// whole-number `Double` like `2.0` would decode back as `.int`. The
    /// tagged form pins each variant unambiguously.
    public enum ExtensionField: Sendable, Equatable, Codable {
        case string(String)
        case int(Int64)
        case double(Double)
        case bool(Bool)
        case data(Data)
        case nested([String: ExtensionField])

        private enum CodingKeys: String, CodingKey {
            case _type
            case value
        }

        private enum Tag: String, Codable {
            case string, int, double, bool, data, nested
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let tag = try container.decode(Tag.self, forKey: ._type)
            switch tag {
            case .string: self = .string(try container.decode(String.self, forKey: .value))
            case .int:    self = .int(try container.decode(Int64.self, forKey: .value))
            case .double: self = .double(try container.decode(Double.self, forKey: .value))
            case .bool:   self = .bool(try container.decode(Bool.self, forKey: .value))
            case .data:   self = .data(try container.decode(Data.self, forKey: .value))
            case .nested: self = .nested(try container.decode([String: ExtensionField].self, forKey: .value))
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .string(let v):
                try container.encode(Tag.string, forKey: ._type)
                try container.encode(v, forKey: .value)
            case .int(let v):
                try container.encode(Tag.int, forKey: ._type)
                try container.encode(v, forKey: .value)
            case .double(let v):
                try container.encode(Tag.double, forKey: ._type)
                try container.encode(v, forKey: .value)
            case .bool(let v):
                try container.encode(Tag.bool, forKey: ._type)
                try container.encode(v, forKey: .value)
            case .data(let v):
                try container.encode(Tag.data, forKey: ._type)
                try container.encode(v, forKey: .value)
            case .nested(let v):
                try container.encode(Tag.nested, forKey: ._type)
                try container.encode(v, forKey: .value)
            }
        }
    }
}

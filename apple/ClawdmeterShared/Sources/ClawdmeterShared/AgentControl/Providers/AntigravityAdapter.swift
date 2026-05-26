import Foundation

/// Per-provider canonical-event adapter for Antigravity / Gemini IDE.
///
/// **F1e strangler-fig migration (D23).** Antigravity's source data lives
/// in two formats:
///   1. **`.db` files** (Antigravity 2.0.6+, plaintext step_payload
///      protobuf containing UsageMetadata sub-messages). Parser:
///      `AntigravityDBUsageParser` → `AntigravityDBUsage` aggregate.
///   2. **`.pb` files** (encrypted legacy archive, byte-÷-4 token
///      estimator fallback). Parser: `AntigravityUsageParser` →
///      `[UsageRecord]`.
///
/// Both yield per-conversation token rollups. F1e canonicalizes each
/// rollup into one `.assistantMessageCompleted` `ProviderRuntimeEvent`
/// with the full breakdown preserved in extension fields.
///
/// **Antigravity is unique among the 5 providers** because the schema is
/// reverse-engineered — there's no published `.proto` file. The
/// `AntigravityDBUsage.recordCount` field tracks how many UsageMetadata
/// sub-messages matched; canonical events surface this via
/// `match_count` extension so the analytics layer can confidence-rate
/// each conversation.
///
/// **Plan:** F1e (Phase 1; D23 strangler-fig) — see
/// `.claude/plans/study-this-codebase-crystalline-shore.md`. F1e is the
/// last F1 adapter — after F1e ships, the F1a-wire → F1e-wire follow-ups
/// flip the strangler-fig flag and F1-finalize deletes the legacy
/// `AgentControlServer` provider branches.
public enum AntigravityAdapter {

    /// Translate a single `AntigravityDBUsage` rollup (from the `.db`
    /// path) into a canonical event. Stateless — callers invoke once
    /// per conversation parsed.
    ///
    /// Use this for Antigravity 2.0.6+ sessions (current-session `.db`
    /// files). For archived `.pb` sessions, use `translate(legacyRecord:)`.
    public static func translate(
        dbUsage usage: AntigravityDBUsage,
        conversationUUID: String,
        timestamp: Date,
        modelName: String,
        cwd: String?,
        sessionId: String,
        sequenceNumber: UInt64,
        providerInstanceId: String? = nil,
        rawBytes: Data? = nil
    ) -> [ProviderRuntimeEvent] {
        // Skip empty rollups — fresh conversations or parser-no-match
        // cases. Matches AntigravityDBUsageParser's empty-fallback
        // contract.
        guard usage.recordCount > 0 else { return [] }

        var antigravityExt: [String: ProviderRuntimeEvent.ExtensionField] = [
            "source": .string("db"),
            "conversation_uuid": .string(conversationUUID),
            "model_name": .string(modelName),
            "match_count": .int(Int64(usage.recordCount)),
            "cached_tokens": .int(Int64(usage.cachedTokens)),
            "reasoning_tokens": .int(Int64(usage.reasoningTokens)),
            "tool_use_tokens": .int(Int64(usage.toolUseTokens))
        ]
        if let cwd { antigravityExt["cwd"] = .string(cwd) }

        return [makeEvent(
            sessionId: sessionId,
            seq: sequenceNumber,
            timestamp: timestamp,
            providerInstanceId: providerInstanceId,
            conversationUUID: conversationUUID,
            payload: .assistantMessageCompleted(
                text: "",
                tokensIn: usage.inputTokens,
                tokensOut: usage.outputTokens
            ),
            rawBytes: rawBytes,
            extensions: ["antigravity": .nested(antigravityExt)]
        )]
    }

    /// Translate a single legacy `.pb` archive UsageRecord into a
    /// canonical event. The legacy parser uses a byte-÷-4 token
    /// estimator when `.pb` decryption fails (see
    /// AntigravityUsageParser); the canonical event marks
    /// `is_estimated:true` so analytics knows the precision tier.
    public static func translate(
        legacyRecord: UsageRecord,
        conversationUUID: String,
        sessionId: String,
        sequenceNumber: UInt64,
        providerInstanceId: String? = nil,
        rawBytes: Data? = nil,
        isEstimated: Bool = true
    ) -> [ProviderRuntimeEvent] {
        let antigravityExt: [String: ProviderRuntimeEvent.ExtensionField] = [
            "source": .string("pb"),
            "conversation_uuid": .string(conversationUUID),
            "model_name": .string(legacyRecord.model),
            "is_estimated": .bool(isEstimated),
            "cache_creation_tokens": .int(Int64(legacyRecord.tokens.cacheCreationTokens)),
            "cache_read_tokens": .int(Int64(legacyRecord.tokens.cacheReadTokens)),
            "reasoning_tokens": .int(Int64(legacyRecord.tokens.reasoningTokens))
        ]

        return [makeEvent(
            sessionId: sessionId,
            seq: sequenceNumber,
            timestamp: legacyRecord.timestamp,
            providerInstanceId: providerInstanceId,
            conversationUUID: conversationUUID,
            payload: .assistantMessageCompleted(
                text: "",
                tokensIn: legacyRecord.tokens.inputTokens,
                tokensOut: legacyRecord.tokens.outputTokens
            ),
            rawBytes: rawBytes,
            extensions: ["antigravity": .nested(antigravityExt)]
        )]
    }

    // MARK: - Event builder

    private static func makeEvent(
        sessionId: String,
        seq: UInt64,
        timestamp: Date,
        providerInstanceId: String?,
        conversationUUID: String,
        payload: ProviderRuntimeEvent.Payload,
        rawBytes: Data?,
        extensions: [String: ProviderRuntimeEvent.ExtensionField]?
    ) -> ProviderRuntimeEvent {
        return ProviderRuntimeEvent(
            id: "antigravity-\(conversationUUID)-\(seq)",
            providerKind: .gemini,
            providerInstanceId: providerInstanceId,
            sessionId: sessionId,
            sequenceNumber: seq,
            emittedAt: timestamp,
            payload: payload,
            rawProviderPayload: rawBytes,
            providerExtensions: extensions
        )
    }
}

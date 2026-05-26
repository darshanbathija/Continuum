import Foundation

/// F1e-wire (strangler-fig per D23): adapter-routed equivalent of
/// `AntigravityUsageParser.parse(...)`.
///
/// Re-projects the canonical `ProviderRuntimeEvent` emitted by
/// `AntigravityAdapter.translate(...)` back into the `[UsageRecord]`
/// shape `UsageHistoryLoader` expects. With the feature flag on, the
/// analytics path calls this; with the flag off, it calls the legacy
/// `AntigravityUsageParser`. The bridge MUST be a behavioral identity
/// over the legacy parser — `F1eParityTests` enforces this.
///
/// **Why a separate type?** The legacy parser is a pure function from
/// (conversation URL + dataDir + brainIndex + modelName) → `[UsageRecord]`.
/// The adapter is two pure functions: one from `AntigravityDBUsage` →
/// `[ProviderRuntimeEvent]` (macOS/iOS only, gated by `#if os(macOS) ||
/// os(iOS)` to match the existing PR #154 guard) and one from
/// `UsageRecord` (the byte-estimated path) → `[ProviderRuntimeEvent]`.
/// The bridge owns the "do the same I/O the legacy parser does + pick
/// the matching adapter overload + reproject the canonical event back
/// into `UsageRecord`" projection in one place.
///
/// **Parity contract.** For every conversation file the legacy parser
/// handles, this MUST return the same `[UsageRecord]` — same provider,
/// timestamp, model, tokens (all categories), repo, and dedupKey. The
/// "no turns" empty-rollup case (legacy returns `[]`) MUST return `[]`
/// here too.
///
/// **Platform behavior.** On watchOS / tvOS the `.db` overload of the
/// adapter doesn't compile (see PR #154's `#if os(macOS) || os(iOS)`
/// guard), so this bridge falls back to the legacy byte-estimator path
/// regardless of the flag. The watch app doesn't ingest Antigravity
/// conversations directly today (it reads aggregated usage from the
/// paired iPhone), so this is a no-op in practice but keeps the
/// cross-platform build green.
///
/// **Plan reference:** F1e-wire (Phase 1; D23 strangler-fig).
public enum AntigravityAdapterUsageBridge {

    /// Parse one Antigravity conversation via the canonical adapter and
    /// project it back into the legacy `UsageRecord` shape. Returns the
    /// same `[UsageRecord]` as `AntigravityUsageParser.parse(...)` for
    /// every input the legacy parser handles. Returns `[]` for the same
    /// "no turns yet" empty-rollup case.
    public static func parse(
        conversationURL: URL,
        antigravityDataDir: URL,
        brainIndex: BrainSummaryIndex,
        modelName: String,
        dedupPrefix: String = "antigravity"
    ) throws -> [UsageRecord] {
        // Mirror the legacy parser's I/O: brain UUID == basename
        // without extension. The probe touches the brain dir to read
        // turn count + last-modified + estimated tokens.
        let brainUUID = conversationURL.deletingPathExtension().lastPathComponent
        let brainURL = antigravityDataDir
            .appendingPathComponent("brain", isDirectory: true)
            .appendingPathComponent(brainUUID, isDirectory: true)

        let probe = ConversationProtoParser.probe(
            conversationURL: conversationURL,
            brainURL: brainURL
        )
        // Empty-rollup contract: legacy returns `[]` when the brain dir
        // has no metadata.json files yet. Mirror that — the adapter's
        // `.db` overload likewise returns `[]` for `recordCount == 0`.
        guard probe.turnCount > 0 else { return [] }

        let repo = repoKey(forBrainUUID: brainUUID, in: brainIndex)
        let timestamp = probe.lastModified
        let dedupKey = "\(dedupPrefix):\(brainUUID)"

        // Build the same TokenTotals the legacy parser would build, but
        // route through the canonical event surface so analytics can
        // observe canonical events firing.
        //
        // `.db` path: try the precise UsageMetadata extractor →
        // `AntigravityAdapter.translate(dbUsage:)` → reproject. Match
        // count == 0 → fall through to the byte estimator (same as
        // legacy).
        //
        // `.pb` path and watchOS / tvOS: build a synthetic legacy
        // `UsageRecord` for the byte estimate → feed it to
        // `AntigravityAdapter.translate(legacyRecord:)` → reproject.
#if os(macOS) || os(iOS)
        if conversationURL.pathExtension == "db" {
            let dbUsage = AntigravityDBUsageParser.parseUsage(dbURL: conversationURL)
            if dbUsage.recordCount > 0 {
                return projectDBRecord(
                    dbUsage: dbUsage,
                    conversationUUID: brainUUID,
                    timestamp: timestamp,
                    modelName: modelName,
                    repo: repo,
                    dedupKey: dedupKey
                )
            }
            // .db with no matches → fall through to byte estimator.
        }
        return projectLegacyRecord(
            probe: probe,
            conversationUUID: brainUUID,
            timestamp: timestamp,
            modelName: modelName,
            repo: repo,
            dedupKey: dedupKey
        )
#else
        // watchOS / tvOS — `.db` overload doesn't compile, route the
        // byte estimator through the cross-platform `.pb` overload.
        return projectLegacyRecord(
            probe: probe,
            conversationUUID: brainUUID,
            timestamp: timestamp,
            modelName: modelName,
            repo: repo,
            dedupKey: dedupKey
        )
#endif
    }

    // MARK: - DB path: AntigravityDBUsage → canonical → UsageRecord

#if os(macOS) || os(iOS)
    private static func projectDBRecord(
        dbUsage: AntigravityDBUsage,
        conversationUUID: String,
        timestamp: Date,
        modelName: String,
        repo: String,
        dedupKey: String
    ) -> [UsageRecord] {
        let events = AntigravityAdapter.translate(
            dbUsage: dbUsage,
            conversationUUID: conversationUUID,
            timestamp: timestamp,
            modelName: modelName,
            cwd: nil, // repo is resolved by the bridge via brainIndex
            sessionId: "",
            sequenceNumber: 0
        )
        guard let usageEvent = events.first(where: { event in
            if case .assistantMessageCompleted = event.payload { return true }
            return false
        }) else {
            // Adapter returned no event for a non-empty rollup — drop to
            // an empty array so the loader treats this conversation as
            // having no records, matching the legacy "no turns" branch.
            return []
        }
        guard case let .assistantMessageCompleted(_, tokensIn, tokensOut) = usageEvent.payload else {
            return []
        }

        // Cache + reasoning tokens live on the canonical extension
        // envelope. Mirror the legacy field mapping exactly:
        //   - cacheReadTokens   ← cached_tokens
        //   - cacheCreationTokens stays 0 (legacy does not set this for .db)
        //   - reasoningTokens   ← reasoning_tokens
        let antigravityExt: [String: ProviderRuntimeEvent.ExtensionField] = {
            guard let outer = usageEvent.providerExtensions?["antigravity"],
                  case let .nested(inner) = outer else { return [:] }
            return inner
        }()
        let cacheRead = extensionInt(antigravityExt["cached_tokens"])
        let reasoning = extensionInt(antigravityExt["reasoning_tokens"])
        let recordCount = extensionInt(antigravityExt["match_count"])

        let tokens = TokenTotals(
            inputTokens: tokensIn,
            outputTokens: tokensOut,
            cacheCreationTokens: 0,
            cacheReadTokens: cacheRead,
            reasoningTokens: reasoning,
            costUSD: 0,
            requestCount: recordCount
        )

        return [UsageRecord(
            provider: .gemini,
            timestamp: usageEvent.emittedAt,
            model: modelName,
            tokens: tokens,
            repo: repo,
            dedupKey: dedupKey
        )]
    }
#endif

    // MARK: - Byte-estimator path: UsageRecord → canonical → UsageRecord

    /// Route the byte-estimator path through `translate(legacyRecord:)`.
    /// We construct the same `UsageRecord` the legacy parser would have
    /// returned, feed it to the adapter, then reproject the canonical
    /// event back. Round-trip identity — proves the byte-estimator data
    /// survives the canonical pipeline.
    private static func projectLegacyRecord(
        probe: ConversationProbe,
        conversationUUID: String,
        timestamp: Date,
        modelName: String,
        repo: String,
        dedupKey: String
    ) -> [UsageRecord] {
        // 70/30 split — same math as `AntigravityUsageParser.byteEstimateTokens`.
        let totalEst = probe.estimatedTokens
        let promptEst = (totalEst * 70) / 100
        let outputEst = totalEst - promptEst

        let legacyTokens = TokenTotals(
            inputTokens: promptEst,
            outputTokens: outputEst,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            reasoningTokens: 0,
            costUSD: 0,
            requestCount: probe.turnCount
        )
        let synth = UsageRecord(
            provider: .gemini,
            timestamp: timestamp,
            model: modelName,
            tokens: legacyTokens,
            repo: repo,
            dedupKey: dedupKey
        )

        let events = AntigravityAdapter.translate(
            legacyRecord: synth,
            conversationUUID: conversationUUID,
            sessionId: "",
            sequenceNumber: 0,
            isEstimated: true
        )
        guard let usageEvent = events.first(where: { event in
            if case .assistantMessageCompleted = event.payload { return true }
            return false
        }) else {
            return []
        }
        guard case let .assistantMessageCompleted(_, tokensIn, tokensOut) = usageEvent.payload else {
            return []
        }

        // Pull cache + reasoning back off the canonical extension. The
        // adapter writes them straight from the input record so the
        // round-trip is lossless.
        let antigravityExt: [String: ProviderRuntimeEvent.ExtensionField] = {
            guard let outer = usageEvent.providerExtensions?["antigravity"],
                  case let .nested(inner) = outer else { return [:] }
            return inner
        }()
        let cacheCreate = extensionInt(antigravityExt["cache_creation_tokens"])
        let cacheRead = extensionInt(antigravityExt["cache_read_tokens"])
        let reasoning = extensionInt(antigravityExt["reasoning_tokens"])

        let tokens = TokenTotals(
            inputTokens: tokensIn,
            outputTokens: tokensOut,
            cacheCreationTokens: cacheCreate,
            cacheReadTokens: cacheRead,
            reasoningTokens: reasoning,
            costUSD: 0,
            requestCount: probe.turnCount
        )

        return [UsageRecord(
            provider: .gemini,
            timestamp: usageEvent.emittedAt,
            model: modelName,
            tokens: tokens,
            repo: repo,
            dedupKey: dedupKey
        )]
    }

    // MARK: - Repo resolution (mirrors the legacy parser)

    private static func repoKey(forBrainUUID uuid: String, in index: BrainSummaryIndex) -> String {
        if let summary = index.byUUID[uuid] {
            if let cwd = summary.cwd { return cwd.path }
            if let title = summary.projectTitle { return title }
        }
        return "antigravity/\(uuid.prefix(8))"
    }

    // MARK: - Extension scalar helpers

    private static func extensionInt(_ field: ProviderRuntimeEvent.ExtensionField?) -> Int {
        guard case let .int(v) = field else { return 0 }
        return Int(v)
    }
}

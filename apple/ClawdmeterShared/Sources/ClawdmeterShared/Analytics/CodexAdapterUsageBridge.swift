import Foundation

/// F1b-wire (strangler-fig per D23): adapter-routed equivalent of
/// `CodexUsageParser.parse(file:)`.
///
/// Re-projects the canonical `ProviderRuntimeEvent`s emitted by
/// `CodexAdapter.translate(...)` back into the `[UsageRecord]` shape
/// `UsageHistoryLoader` expects. With the feature flag on, the
/// analytics path calls this; with the flag off, it calls the legacy
/// `CodexUsageParser`. The bridge MUST be a behavioral identity over
/// the legacy parser — `F1bParityTests` enforces this.
///
/// **Why file-level (not line-level like Claude)?** `CodexAdapter` is
/// stateful — cumulative→delta token math + running `currentCwd` /
/// `currentModel` must survive across `translate(line:)` calls within a
/// session. The Claude bridge can be line-level because `ClaudeAdapter`
/// is stateless; the Codex bridge has to construct one `CodexAdapter`
/// per file and feed every line through it in order.
///
/// **Parity contract.** For every Codex JSONL file, this MUST return
/// the same `[UsageRecord]` as `CodexUsageParser.parse(file:)` — same
/// provider, timestamps, models, tokens (input minus cached → input,
/// cached → cacheRead, output already rolls reasoning), repos, and
/// dedup keys (always nil for Codex). Cases the legacy parser drops
/// (zero-delta heartbeat, malformed line, non-monotonic session reset
/// re-baseline rather than emit-negative) MUST be reproduced here too.
///
/// **Plan reference:** F1b-wire (Phase 1; D23 strangler-fig).
public enum CodexAdapterUsageBridge {

    /// Parse a Codex JSONL rollout file via the canonical adapter and
    /// project every `.assistantMessageCompleted` event back into the
    /// legacy `UsageRecord` shape. The adapter is stateful, so we
    /// construct exactly one per file and walk lines in order.
    public static func parseFile(at url: URL) throws -> [UsageRecord] {
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return [] }

        // One adapter per file = one Codex session. The sessionId here is
        // a Clawdmeter-internal handle for the event stream; the
        // analytics layer doesn't read it off the canonical event, so
        // a stable per-file identifier (the path) is sufficient.
        let adapter = CodexAdapter(sessionId: url.path)

        var records: [UsageRecord] = []
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        for rawLine in lines {
            let lineData = Data(rawLine)
            guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }
            let events = adapter.translate(line: json, rawBytes: nil)
            for event in events {
                guard let record = projectToUsageRecord(event: event) else { continue }
                records.append(record)
            }
        }

        return records
    }

    // MARK: - Event → UsageRecord projection

    /// Pull an `.assistantMessageCompleted` event back into the legacy
    /// `UsageRecord` shape using the `codex` extension envelope. Returns
    /// nil for every other event payload — the bridge only emits records
    /// where legacy emitted records (token_count snapshots with a
    /// non-zero delta). Zero-delta heartbeat events are already dropped
    /// by `CodexAdapter` (see `emitTokenCount`'s `delta.total > 0`
    /// guard), so any `.assistantMessageCompleted` we see has a non-zero
    /// delta and should produce a record.
    private static func projectToUsageRecord(
        event: ProviderRuntimeEvent
    ) -> UsageRecord? {
        guard case let .assistantMessageCompleted(_, tokensIn, tokensOut) = event.payload else {
            return nil
        }

        // The adapter wraps Codex-specific fields under
        // `providerExtensions["codex"]` as a nested map. Pull the model
        // + cwd off the running extension envelope.
        let codexExt: [String: ProviderRuntimeEvent.ExtensionField] = {
            guard let outer = event.providerExtensions?["codex"],
                  case let .nested(inner) = outer else { return [:] }
            return inner
        }()

        // Cache-read tokens are stored under `delta_cache_read` so the
        // bridge can pull the cached portion separately from the
        // already-decompounded `input` field (which is the legacy
        // `input_tokens - cached_input_tokens` value). This mirrors the
        // legacy parser's split: cached portion → cacheReadTokens,
        // remainder → inputTokens.
        let cacheRead = extensionInt(codexExt["delta_cache_read"])

        let tokens = TokenTotals(
            inputTokens: tokensIn,
            outputTokens: tokensOut,
            cacheCreationTokens: 0,
            cacheReadTokens: cacheRead,
            reasoningTokens: 0,
            costUSD: 0
        )

        // Legacy parser's zero-delta drop is mirrored inside the adapter
        // (delta.total > 0 in emitTokenCount). Defense in depth — match
        // legacy's `delta.totalTokens == 0` guard here too in case the
        // contract ever drifts.
        if tokens.totalTokens == 0 { return nil }

        // Model — extension carries the running `currentModel` value
        // (initialized to "gpt-5" default, updated on every
        // `turn_context.model`). Legacy parser uses the same fallback.
        let model = extensionString(codexExt["model"]) ?? "gpt-5"

        // Repo — extension carries the running `currentCwd` value
        // (updated on `session_meta` / `turn_context` lines). Legacy
        // parser uses `RepoIdentity.normalize(cwd)`; reproduce that
        // here so the aggregator's per-repo bucketing is identical.
        let repo: RepoKey? = {
            guard let cwd = extensionString(codexExt["cwd"]),
                  !cwd.isEmpty else { return nil }
            return RepoIdentity.normalize(cwd)
        }()

        // Dedup key — legacy always emits nil for Codex (no message ID
        // semantics that map to a stable cross-file row identifier).
        // Mirror that.
        return UsageRecord(
            provider: .codex,
            timestamp: event.emittedAt,
            model: model,
            tokens: tokens,
            repo: repo,
            dedupKey: nil
        )
    }

    // MARK: - Extension scalar helpers

    private static func extensionString(_ field: ProviderRuntimeEvent.ExtensionField?) -> String? {
        guard case let .string(v) = field else { return nil }
        return v
    }

    private static func extensionInt(_ field: ProviderRuntimeEvent.ExtensionField?) -> Int {
        guard case let .int(v) = field else { return 0 }
        return Int(v)
    }
}

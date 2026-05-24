import Foundation

/// Normalized per-event row emitted by either parser. Aggregator only sees
/// this shape — Claude vs Codex differences are absorbed by the parsers.
///
/// Per plan A12: `repo` is per-line for Claude (one JSONL can hold lines with
/// multiple `cwd` values), per-file for Codex (verified one `session_meta`
/// per rollout). `nil` means the source didn't expose a working directory;
/// the aggregator groups those under `"(unknown)"`.
///
/// `dedupKey` is set for Claude (`messageId:requestId`) and `nil` for Codex
/// (deltas are derived from cumulative state inside a single file; dedup is
/// already implicit). The aggregator inserts every non-nil key into a global
/// `Set` and drops records whose key was already seen — that's how we catch
/// the cross-file duplication Claude occasionally produces when sessions
/// resume.
public struct UsageRecord: Sendable, Equatable {

    public enum Provider: String, Codable, Sendable, Equatable, CaseIterable {
        case claude
        case codex
        case gemini
        /// OpenCode (D11/D12, v1.1 — wire v13). Adds a 4th analytics
        /// column + menu-bar dollar gauge. Cost mapping: the
        /// `OpencodeUsageMapper` resolves the *underlying model* the
        /// OpenCode server invoked (Anthropic, OpenAI, Google) and
        /// looks up that model's rate card via `Pricing.cost(for:tokens:)`.
        /// OpenCode itself is the orchestrator; analytics tag the slice
        /// under `.opencode` so users see how much they spent through
        /// the OpenCode pipeline regardless of the underlying provider.
        case opencode
        /// Cursor usage attributed to Cursor Agent CLI / SDK runs.
        case cursor
    }

    public let provider: Provider
    public let timestamp: Date
    public let model: String
    public let tokens: TokenTotals
    /// Absolute working directory path (e.g. `/Users/x/Downloads/CC Watch`).
    /// `nil` when the source didn't expose a cwd. Aggregator buckets `nil`
    /// records under the literal repo key `"(unknown)"`.
    public let repo: String?
    /// Stable cross-file identifier. `messageId:requestId` for Claude, `nil`
    /// for Codex.
    public let dedupKey: String?

    public init(
        provider: Provider,
        timestamp: Date,
        model: String,
        tokens: TokenTotals,
        repo: String?,
        dedupKey: String?
    ) {
        self.provider = provider
        self.timestamp = timestamp
        self.model = model
        self.tokens = tokens
        self.repo = repo
        self.dedupKey = dedupKey
    }
}

/// Stable string key for the per-repo aggregation maps. Either the normalized
/// absolute cwd path or the literal `"(unknown)"` sentinel.
public typealias RepoKey = String

extension RepoKey {
    public static let unknown: RepoKey = "(unknown)"
    /// Bucket for cwds that don't resolve to a git repository — random
    /// UUIDs, home-directory sessions, ad-hoc folders. Surfaced as a
    /// single "Other" row in the by-repo list so the UI isn't polluted
    /// with workspace IDs and ambient directories that aren't real repos.
    public static let other: RepoKey = "(other)"
}

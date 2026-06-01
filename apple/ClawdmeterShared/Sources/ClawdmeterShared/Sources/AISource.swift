import Foundation

/// Source of `UsageData` for a single AI provider.
///
/// Plan D8: V1 has one implementation (`AnthropicSource`). V2 adds `CodexSource`.
/// V3 fuses both. The protocol exists from day 1 so multi-source work is a config
/// change, not a refactor.
public protocol AISource: AnyObject, Sendable {

    /// Stable identifier, e.g. "anthropic", "codex". Used for logging and disambiguation.
    var providerID: String { get }

    /// Human-readable display name, e.g. "Claude (Anthropic)".
    var displayName: String { get }

    /// Whether the source can poll right now. False if not authenticated.
    var isAuthenticated: Bool { get }

    /// Poll for the latest `UsageData`.
    /// - Returns: a `UsageData` snapshot.
    /// - Throws: `AISourceError` on any failure (auth, network, parse).
    func poll() async throws -> UsageData

    /// Refresh credentials if they're stale. Implementations should be bounded
    /// (plan E7: 2 attempts per 10-min window).
    /// - Returns: true on success, false on hard refresh failure (user must re-auth).
    func refreshCredentialsIfNeeded() async throws -> Bool

    /// Cheap, stat-only check: has this source's on-disk data changed since
    /// `date`? Lets `UsagePoller` skip a full `poll()` on a quiet machine so it
    /// does NOT re-read the provider's cross-app dir every tick (the read that
    /// surfaces the macOS "access data from other apps" prompt). Default
    /// returns `true` (always poll); file-backed sources that read another
    /// tool's directory override it to stat their data dir's newest mtime.
    /// Must be a protocol requirement (not just an extension method) so it
    /// dispatches dynamically through `any AISource`.
    /// - Parameter date: the last successful-poll timestamp, or nil if none yet.
    /// - Returns: true if the data may have changed (poll), false if unchanged.
    func dataChangedSince(_ date: Date?) -> Bool
}

public extension AISource {
    /// Default: always poll. Sources that don't read a cross-app data dir
    /// (keychain-backed Claude/Cursor, network-only sources, test stubs) inherit
    /// this and keep their existing every-tick behavior.
    func dataChangedSince(_ date: Date?) -> Bool { true }
}

/// Errors any `AISource` can throw. Stable across platforms.
public enum AISourceError: Error, Sendable {
    case unauthenticated
    case rateLimited(retryAfter: TimeInterval?)
    case authExpired                  // Refresh token also expired; user must re-auth
    case networkFailure(underlying: Error?)
    case malformedResponse(detail: String)
    case dataSourceContractViolation(detail: String) // Phase 0 contract not met
}

extension AISourceError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .unauthenticated:
            return "AISourceError.unauthenticated"
        case .rateLimited(let retry):
            return "AISourceError.rateLimited(retryAfter: \(retry.map { "\($0)s" } ?? "nil"))"
        case .authExpired:
            return "AISourceError.authExpired"
        case .networkFailure(let err):
            return "AISourceError.networkFailure(\(err.map { "\($0)" } ?? "nil"))"
        case .malformedResponse(let detail):
            return "AISourceError.malformedResponse(\(detail))"
        case .dataSourceContractViolation(let detail):
            return "AISourceError.dataSourceContractViolation(\(detail))"
        }
    }
}

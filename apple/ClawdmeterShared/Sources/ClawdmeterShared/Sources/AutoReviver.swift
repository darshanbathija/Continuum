import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(OSLog)
import OSLog
#endif

/// Auto-revive used to keep the 5-hour session window warm by posting a tiny
/// model request. That creates visible throwaway Claude conversations and
/// consumes quota, so the shipped implementation is intentionally disabled
/// until a non-generative provider endpoint can do this.
@MainActor
public final class AutoReviver: ObservableObject {

    public enum Outcome: Sendable, Equatable {
        case fired
        case throttled
        case noToken
        case httpError(Int)
        case networkError
        case disabled
    }

    public struct Result: Sendable, Equatable {
        public let outcome: Outcome
        public let at: Date
    }

    @Published public private(set) var lastResult: Result?
    @Published public private(set) var fireCount: Int = 0

    public var isEnabled: Bool = false
    public let model: String
    public let endpoint: URL
    public let anthropicVersion: String?

    private let logger: Logger

    public init(
        tokenProvider: TokenProvider,
        session: URLSession = .shared,
        model: String = "claude-haiku-4-5",
        endpoint: URL = URL(string: "https://api.anthropic.com/api/oauth/usage")!,
        anthropicVersion: String? = "2023-06-01"
    ) {
        _ = tokenProvider
        _ = session
        self.model = model
        self.endpoint = endpoint
        self.anthropicVersion = anthropicVersion
        self.logger = Logger(subsystem: "com.clawdmeter.mac", category: "AutoReviver.\(model)")
    }

    /// Call this every clock tick. Returns immediately if conditions aren't met.
    /// Conditions:
    ///   - `isEnabled` is true
    ///   - `usage` is present
    ///
    /// Network firing is disabled; this records `.disabled` once so stale
    /// callers can surface that the feature is unavailable without spending
    /// quota.
    public func tick(usage: UsageData, now: Date) async {
        guard isEnabled else { return }
        _ = usage
        if lastResult?.outcome != .disabled {
            logger.warning("AutoReviver: disabled; refusing to send quota keepalive")
            lastResult = Result(outcome: .disabled, at: now)
        }
    }

    /// Manual trigger (e.g., a "Revive now" button).
    public func fireNow() async {
        let now = Date()
        logger.warning("AutoReviver: disabled; refusing manual quota keepalive")
        lastResult = Result(outcome: .disabled, at: now)
    }
}

import Foundation
#if canImport(OSLog)
import OSLog
#endif

/// Auto-revive: when the 5-hour session window expires, fire a 1-token "Hi" to
/// Claude Haiku 4.5 so a new window immediately starts ticking. Keeps the
/// countdown perpetually active instead of going idle.
///
/// Cost: ~5-10 input tokens + 1 output token per fire. With a 5h cadence, that's
/// roughly 4-5 pings/day for a continuously-running app.
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

    private let tokenProvider: TokenProvider
    private let session: URLSession
    private let logger: Logger
    private var lastFireAt: Date?
    /// Don't fire more than once per cool-off window (defends against bursty ticks).
    private let cooloffSeconds: TimeInterval = 120
    private var inFlight: Bool = false

    public init(
        tokenProvider: TokenProvider,
        session: URLSession = .shared,
        model: String = "claude-haiku-4-5",
        endpoint: URL = URL(string: "https://api.anthropic.com/v1/messages")!,
        anthropicVersion: String? = "2023-06-01"
    ) {
        self.tokenProvider = tokenProvider
        self.session = session
        self.model = model
        self.endpoint = endpoint
        self.anthropicVersion = anthropicVersion
        self.logger = Logger(subsystem: "com.clawdmeter.mac", category: "AutoReviver.\(model)")
    }

    /// Call this every clock tick. Returns immediately if conditions aren't met.
    /// Conditions:
    ///   - `isEnabled` is true
    ///   - `usage` is present
    ///   - `now` has passed the session reset epoch (>= sessionEpoch - 1s; small
    ///     bias to fire just before so the new window starts contiguous)
    ///   - last fire was more than `cooloffSeconds` ago
    public func tick(usage: UsageData, now: Date) async {
        guard isEnabled else { return }
        let resetDate = Date(timeIntervalSince1970: TimeInterval(usage.sessionEpoch))
        // Fire as soon as `now` is at or past the reset moment.
        guard now >= resetDate.addingTimeInterval(-1) else { return }
        if let last = lastFireAt, now.timeIntervalSince(last) < cooloffSeconds { return }
        if inFlight { return }
        await fire(at: now)
    }

    /// Manual trigger (e.g., a "Revive now" button).
    public func fireNow() async {
        guard !inFlight else { return }
        await fire(at: Date())
    }

    private func fire(at now: Date) async {
        inFlight = true
        defer { inFlight = false }
        lastFireAt = now

        guard let token = tokenProvider.currentAccessToken else {
            logger.warning("AutoReviver: no token; skipping")
            lastResult = Result(outcome: .noToken, at: now)
            return
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let anthropicVersion {
            request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1,
            "messages": [["role": "user", "content": "Hi"]],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (_, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse {
                if (200..<300).contains(http.statusCode) {
                    fireCount += 1
                    lastResult = Result(outcome: .fired, at: now)
                    logger.info("AutoReviver: fired ping to \(self.model); response \(http.statusCode)")
                } else {
                    lastResult = Result(outcome: .httpError(http.statusCode), at: now)
                    logger.error("AutoReviver: HTTP \(http.statusCode)")
                }
            }
        } catch {
            lastResult = Result(outcome: .networkError, at: now)
            logger.error("AutoReviver: network error \(String(describing: error))")
        }
    }
}

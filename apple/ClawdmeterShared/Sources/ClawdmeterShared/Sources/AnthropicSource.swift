import Foundation
import OSLog

private let logger = Logger(subsystem: "com.clawdmeter.shared", category: "AnthropicSource")

/// V1 `AISource` implementation against the Phase 0 Data Source Contract.
///
/// Calls `POST https://api.anthropic.com/v1/messages` with a 1-token Haiku request
/// and reads the `anthropic-ratelimit-unified-*` response headers. See
/// The headers we depend on are documented in this file.
public final class AnthropicSource: AISource, @unchecked Sendable {

    public let providerID = "anthropic"
    public let displayName = "Claude (Anthropic)"

    private let tokenProvider: TokenProvider
    private let urlSession: URLSession
    private let endpoint: URL
    private let userAgent: String

    /// Bounded refresh attempts per E7. Use a window to prevent infinite retries.
    private var refreshAttempts: [Date] = []
    private let refreshWindowSeconds: TimeInterval = 600 // 10 min
    private let maxRefreshAttemptsPerWindow = 2

    public init(
        tokenProvider: TokenProvider,
        urlSession: URLSession? = nil,
        endpoint: URL = URL(string: "https://api.anthropic.com/v1/messages")!,
        userAgent: String = "claude-code/2.1.5"
    ) {
        self.tokenProvider = tokenProvider
        // Use a per-source URLSession instead of `.shared` — observed hangs on
        // macOS Tahoe with `URLSession.shared.data(for:)` from Swift Concurrency
        // tasks when multiple `AISource` instances share the session.
        if let urlSession {
            self.urlSession = urlSession
        } else {
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 30
            cfg.timeoutIntervalForResource = 60
            cfg.waitsForConnectivity = false
            self.urlSession = URLSession(configuration: cfg)
        }
        self.endpoint = endpoint
        self.userAgent = userAgent
    }

    public var isAuthenticated: Bool {
        tokenProvider.hasToken
    }

    public func poll() async throws -> UsageData {
        logger.info("AnthropicSource.poll() ENTER")
        guard let token = tokenProvider.currentAccessToken else {
            logger.warning("AnthropicSource.poll: no token")
            throw AISourceError.unauthenticated
        }
        // Fingerprint = first 14 chars (the well-known `sk-ant-oat01-` prefix
        // plus the next char) + last 4. Safe to log because that's not enough
        // to reconstruct the token, but enough to confirm Mac and iOS are
        // sending the same string.
        let fp = token.count > 18
            ? "\(token.prefix(14))…\(token.suffix(4))"
            : "(short:\(token.count))"
        logger.info("AnthropicSource.poll: token len=\(token.count) fp=\(fp, privacy: .public), making HTTPS")
        defer { logger.info("AnthropicSource.poll: HTTPS leg done") }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let bodyJSON: [String: Any] = [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 1,
            "messages": [["role": "user", "content": "hi"]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: bodyJSON)

        // Use dataTask + continuation instead of URLSession.data(for:) — the
        // async API hangs on macOS Tahoe with `URLSession.shared` from
        // cooperative tasks when multiple sessions are active. The completion-
        // handler API doesn't have this issue.
        struct NetResult: Sendable { let data: Data; let response: URLResponse }
        let result: NetResult
        do {
            result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NetResult, Error>) in
                let task = urlSession.dataTask(with: request) { data, response, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let data, let response {
                        continuation.resume(returning: NetResult(data: data, response: response))
                    } else {
                        continuation.resume(throwing: URLError(.unknown))
                    }
                }
                task.resume()
            }
        } catch {
            throw AISourceError.networkFailure(underlying: error)
        }
        let response = result.response

        guard let http = response as? HTTPURLResponse else {
            throw AISourceError.malformedResponse(detail: "Non-HTTP response")
        }

        switch http.statusCode {
        case 200:
            return try parseUsage(from: http)
        case 401:
            // Auth chain handled in poller's bounded-retry wrapper (E7).
            throw AISourceError.unauthenticated
        case 429:
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw AISourceError.rateLimited(retryAfter: retryAfter)
        case 400...499:
            throw AISourceError.malformedResponse(detail: "Client error: \(http.statusCode)")
        case 500...599:
            throw AISourceError.networkFailure(underlying: nil)
        default:
            throw AISourceError.malformedResponse(detail: "Unexpected status: \(http.statusCode)")
        }
    }

    public func refreshCredentialsIfNeeded() async throws -> Bool {
        let now = Date()
        // Drop attempts older than the window.
        refreshAttempts = refreshAttempts.filter { now.timeIntervalSince($0) <= refreshWindowSeconds }
        guard refreshAttempts.count < maxRefreshAttemptsPerWindow else {
            throw AISourceError.authExpired
        }
        refreshAttempts.append(now)
        return try await tokenProvider.refreshIfNeeded()
    }

    // MARK: - Header parsing

    /// Parse Phase 0 Data Source Contract headers into a `UsageData` snapshot.
    private func parseUsage(from response: HTTPURLResponse) throws -> UsageData {
        func headerFloat(_ name: String) -> Double? {
            response.value(forHTTPHeaderField: name).flatMap(Double.init)
        }
        func headerInt(_ name: String) -> Int? {
            response.value(forHTTPHeaderField: name).flatMap(Int.init)
        }
        func headerString(_ name: String) -> String? {
            response.value(forHTTPHeaderField: name)
        }

        guard let s5hUtil = headerFloat("anthropic-ratelimit-unified-5h-utilization"),
              let s5hReset = headerInt("anthropic-ratelimit-unified-5h-reset"),
              let s7dUtil = headerFloat("anthropic-ratelimit-unified-7d-utilization"),
              let s7dReset = headerInt("anthropic-ratelimit-unified-7d-reset")
        else {
            throw AISourceError.dataSourceContractViolation(
                detail: "Missing unified rate-limit headers (5h or 7d utilization/reset)."
            )
        }

        let serverDate = parseServerDate(from: response) ?? Date()
        let serverEpoch = Int(serverDate.timeIntervalSince1970)

        let sessionResetMins = max(0, (s5hReset - serverEpoch) / 60)
        let weeklyResetMins = max(0, (s7dReset - serverEpoch) / 60)

        let sessionStatus = headerString("anthropic-ratelimit-unified-5h-status") ?? "unknown"
        let weeklyStatus = headerString("anthropic-ratelimit-unified-7d-status") ?? "unknown"
        let compositeStatus: UsageData.Status = {
            if sessionStatus == "limited" || weeklyStatus == "limited" { return .limited }
            if sessionStatus == "allowed" && weeklyStatus == "allowed" { return .allowed }
            return .unknown
        }()

        let claim: UsageData.BindingWindow = {
            switch headerString("anthropic-ratelimit-unified-representative-claim") {
            case "five_hour": return .fiveHour
            case "seven_day": return .sevenDay
            default: return .unknown
            }
        }()

        return UsageData(
            sessionPct: Int((s5hUtil * 100).rounded()),
            sessionResetMins: sessionResetMins,
            sessionEpoch: s5hReset,
            weeklyPct: Int((s7dUtil * 100).rounded()),
            weeklyResetMins: weeklyResetMins,
            weeklyEpoch: s7dReset,
            status: compositeStatus,
            representativeClaim: claim,
            updatedAt: serverDate,
            organizationID: headerString("anthropic-organization-id")
        )
    }

    /// Parse RFC 7231 `date:` header into a `Date`.
    private func parseServerDate(from response: HTTPURLResponse) -> Date? {
        guard let raw = response.value(forHTTPHeaderField: "date") else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: raw)
    }
}

/// Indirection so OAuth token loading can be mocked in tests and varied per platform
/// (iOS Keychain via ASWebAuthenticationSession, macOS Keychain via SecKeychain access,
/// iCloud Keychain shared item for Mac/iOS cross-device).
public protocol TokenProvider: Sendable {
    var currentAccessToken: String? { get }
    var hasToken: Bool { get }
    /// Refresh if the cached token is near expiry.
    /// - Returns: true on success, false if no refresh was needed; throws on hard failure.
    func refreshIfNeeded() async throws -> Bool
}

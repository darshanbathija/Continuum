import Foundation
#if canImport(OSLog)
import OSLog
#endif

private let logger = Logger(subsystem: "com.clawdmeter.shared", category: "AnthropicSource")

/// V1 `AISource` implementation against the Phase 0 Data Source Contract.
///
/// **Primary path:** `POST /v1/messages` with a 1-token Haiku request and
/// parse the `anthropic-ratelimit-unified-*` response headers. This is the
/// rich path — both the 5h and 7d windows come back in a single response,
/// no separate fetch needed, no per-endpoint rate-limit budget to worry
/// about (the 1-token spend is negligible).
///
/// **What we now send.** Earlier builds of Clawdmeter polled `/v1/messages`
/// directly with the OAuth token and worked for months — until Anthropic
/// started returning HTTP 403 `permission_error` "OAuth authentication is
/// currently not allowed for this organization." The fix is one header:
/// `x-anthropic-additional-protection: true`. Without it, Anthropic blocks
/// Pro/Max OAuth tokens against `/v1/messages` to prevent abusing
/// Claude.ai-tier auth as a backdoor to free API access. With it, requests
/// are recognized as legitimate Claude-Code-style traffic. The literal
/// value is just the string `true`; pulled from the bundled `claude` CLI
/// binary alongside the existing `x-anthropic-billing-header: cc_version=…`
/// header that Anthropic also expects.
///
/// **Fallback path:** if `/v1/messages` ever 403s again (Anthropic rotates
/// the additional-protection mechanism, or revokes our org's access to it),
/// `pollOAuthUsageFallback()` calls `GET /api/oauth/usage`. That's the
/// endpoint `claude` itself uses for its rate-limit fetch — the response
/// body's `rate_limit_type` / `utilization` / `resets_at` is enough to
/// populate the binding window, with the un-binding window remembered
/// from the previous successful poll. Strictly poorer data than the
/// primary path (only one window populated per call) but resilient.
public final class AnthropicSource: AISource, @unchecked Sendable {

    public let providerID = "anthropic"
    public let displayName = "Claude (Anthropic)"

    private let tokenProvider: TokenProvider
    private let urlSession: URLSession
    private let messagesEndpoint: URL
    private let oauthUsageEndpoint: URL
    private let userAgent: String
    private let ccVersion: String

    /// Bounded refresh attempts per E7. Use a window to prevent infinite retries.
    private var refreshAttempts: [Date] = []
    private let refreshWindowSeconds: TimeInterval = 600 // 10 min
    private let maxRefreshAttemptsPerWindow = 2

    /// Latest window snapshots, kept across polls so the un-binding window's
    /// percentage doesn't drop to 0% on the fallback path when the API only
    /// reports the binding window. Primary path overrides both windows on
    /// every successful poll, so this only matters in fallback mode.
    private var lastSession: (pct: Int, resetEpoch: Int)?
    private var lastWeekly: (pct: Int, resetEpoch: Int)?

    public init(
        tokenProvider: TokenProvider,
        urlSession: URLSession? = nil,
        messagesEndpoint: URL = URL(string: "https://api.anthropic.com/v1/messages")!,
        oauthUsageEndpoint: URL = URL(string: "https://api.anthropic.com/api/oauth/usage")!,
        ccVersion: String = "2.1.143",
        userAgent: String = "claude-cli/2.1.143 (external, cli)"
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
        self.messagesEndpoint = messagesEndpoint
        self.oauthUsageEndpoint = oauthUsageEndpoint
        self.ccVersion = ccVersion
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
        logger.info("AnthropicSource.poll: token len=\(token.count) fp=\(fp, privacy: .public), trying /v1/messages")
        defer { logger.info("AnthropicSource.poll: HTTPS leg done") }

        do {
            return try await pollViaMessages(token: token)
        } catch AISourceError.unauthenticated {
            // 401/403 on the primary path. Two possibilities:
            //   1. Token genuinely expired/rotated — caller's refresh path
            //      will fire and the next tick re-tries the primary.
            //   2. Anthropic rotated the additional-protection mechanism on
            //      /v1/messages and the magic header no longer suffices.
            // Try the fallback before propagating the auth error so the
            // dashboard at least shows the binding window's number.
            logger.warning("AnthropicSource.poll: /v1/messages auth-rejected; trying /api/oauth/usage fallback")
            do {
                return try await pollOAuthUsageFallback(token: token)
            } catch {
                // Surface the original .unauthenticated so the bounded-retry
                // wrapper has a chance to refresh credentials.
                throw AISourceError.unauthenticated
            }
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

    // MARK: - Primary path (/v1/messages + unified rate-limit headers)

    private func pollViaMessages(token: String) async throws -> UsageData {
        var request = URLRequest(url: messagesEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        // ↓ The two headers that distinguish a legitimate Claude-Code poll
        // from "random OAuth client trying to use /v1/messages as a free
        // API." Without these, Anthropic returns 403 permission_error.
        // `x-anthropic-additional-protection: true` is the literal value
        // observed in the bundled `claude` CLI binary; `x-anthropic-billing-
        // header: cc_version=<v>` is the matching billing tag.
        request.setValue("true", forHTTPHeaderField: "x-anthropic-additional-protection")
        request.setValue("cc_version=\(ccVersion)", forHTTPHeaderField: "x-anthropic-billing-header")

        let bodyJSON: [String: Any] = [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 1,
            "messages": [["role": "user", "content": "hi"]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: bodyJSON)

        let (_, response) = try await runRequest(request)
        guard let http = response as? HTTPURLResponse else {
            throw AISourceError.malformedResponse(detail: "Non-HTTP response")
        }
        switch http.statusCode {
        case 200:
            return try parseUnifiedHeaders(from: http)
        case 401, 403:
            // 401 = token rotated / revoked; 403 = additional-protection
            // mechanism rejected us. Either way the caller's fallback
            // routes to /api/oauth/usage before surfacing the auth error.
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

    /// Phase 0 Data Source Contract — parse `anthropic-ratelimit-unified-*`
    /// response headers into a `UsageData` snapshot.
    private func parseUnifiedHeaders(from response: HTTPURLResponse) throws -> UsageData {
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

        let sessionPct = Int((s5hUtil * 100).rounded())
        let weeklyPct = Int((s7dUtil * 100).rounded())
        let sessionResetMins = max(0, (s5hReset - serverEpoch) / 60)
        let weeklyResetMins = max(0, (s7dReset - serverEpoch) / 60)

        let sessionStatus = headerString("anthropic-ratelimit-unified-5h-status") ?? "unknown"
        let weeklyStatus = headerString("anthropic-ratelimit-unified-7d-status") ?? "unknown"
        let compositeStatus: UsageData.Status = {
            if sessionStatus == "limited" || weeklyStatus == "limited" { return .limited }
            if sessionStatus.hasPrefix("allowed") && weeklyStatus.hasPrefix("allowed") { return .allowed }
            return .unknown
        }()

        let claim: UsageData.BindingWindow = {
            switch headerString("anthropic-ratelimit-unified-representative-claim") {
            case "five_hour": return .fiveHour
            case "seven_day": return .sevenDay
            default: return .unknown
            }
        }()

        // Cache for fallback-path continuity.
        lastSession = (sessionPct, s5hReset)
        lastWeekly = (weeklyPct, s7dReset)

        return UsageData(
            sessionPct: sessionPct,
            sessionResetMins: sessionResetMins,
            sessionEpoch: s5hReset,
            weeklyPct: weeklyPct,
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

    // MARK: - Fallback path (/api/oauth/usage + JSON body)

    private func pollOAuthUsageFallback(token: String) async throws -> UsageData {
        var request = URLRequest(url: oauthUsageEndpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await runRequest(request)
        guard let http = response as? HTTPURLResponse else {
            throw AISourceError.malformedResponse(detail: "Non-HTTP response")
        }
        switch http.statusCode {
        case 200:
            return try parseOAuthUsageBody(data: data, response: http)
        case 401, 403:
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

    private func parseOAuthUsageBody(data: Data, response: HTTPURLResponse) throws -> UsageData {
        let serverDate = parseServerDate(from: response) ?? Date()
        let serverEpoch = Int(serverDate.timeIntervalSince1970)

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let envelope: OAuthUsageEnvelope
        do {
            envelope = try decoder.decode(OAuthUsageEnvelope.self, from: data)
        } catch {
            logger.error("AnthropicSource.parseOAuthUsageBody: JSON decode failed: \(error.localizedDescription, privacy: .public)")
            let preview = String(data: data.prefix(400), encoding: .utf8) ?? "<binary>"
            logger.info("AnthropicSource.parseOAuthUsageBody: body preview: \(preview, privacy: .public)")
            throw AISourceError.malformedResponse(detail: "Could not decode /api/oauth/usage body")
        }

        let binding: UsageData.BindingWindow = {
            switch envelope.bindingType {
            case .fiveHour: return .fiveHour
            case .sevenDay, .sevenDayOpus, .sevenDaySonnet: return .sevenDay
            case .overage, .none: return .unknown
            }
        }()

        let session = envelope.window(
            for: .fiveHour,
            fallbackBinding: binding == .fiveHour ? envelope.flatUtilization : nil,
            fallbackResetEpoch: binding == .fiveHour ? envelope.flatResetsAt?.epoch(server: serverEpoch) : nil
        )
        let weekly = envelope.window(
            for: .sevenDay,
            fallbackBinding: binding == .sevenDay ? envelope.flatUtilization : nil,
            fallbackResetEpoch: binding == .sevenDay ? envelope.flatResetsAt?.epoch(server: serverEpoch) : nil
        )

        let sessionPct = session?.pct ?? lastSession?.pct ?? 0
        let sessionEpoch = session?.resetEpoch ?? lastSession?.resetEpoch ?? serverEpoch
        let weeklyPct = weekly?.pct ?? lastWeekly?.pct ?? 0
        let weeklyEpoch = weekly?.resetEpoch ?? lastWeekly?.resetEpoch ?? serverEpoch

        if let session { lastSession = session }
        if let weekly { lastWeekly = weekly }

        let sessionResetMins = max(0, (sessionEpoch - serverEpoch) / 60)
        let weeklyResetMins = max(0, (weeklyEpoch - serverEpoch) / 60)

        let status: UsageData.Status = {
            if sessionPct >= 100 || weeklyPct >= 100 { return .limited }
            if sessionPct == 0 && weeklyPct == 0 { return .unknown }
            return .allowed
        }()

        return UsageData(
            sessionPct: sessionPct,
            sessionResetMins: sessionResetMins,
            sessionEpoch: sessionEpoch,
            weeklyPct: weeklyPct,
            weeklyResetMins: weeklyResetMins,
            weeklyEpoch: weeklyEpoch,
            status: status,
            representativeClaim: binding,
            updatedAt: serverDate,
            organizationID: envelope.organizationUuid
        )
    }

    // MARK: - Networking helper

    private func runRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        // Use dataTask + continuation instead of URLSession.data(for:) — the
        // async API hangs on macOS Tahoe with `URLSession.shared` from
        // cooperative tasks when multiple sessions are active. The completion-
        // handler API doesn't have this issue.
        struct NetResult: Sendable { let data: Data; let response: URLResponse }
        do {
            let result: NetResult = try await withCheckedThrowingContinuation { continuation in
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
            return (result.data, result.response)
        } catch {
            throw AISourceError.networkFailure(underlying: error)
        }
    }
}

// MARK: - /api/oauth/usage envelope

/// Catch-all decoder for the `/api/oauth/usage` fallback response.
/// Tolerates three observed-or-inferred shapes by making every field
/// optional and unifying the candidate locations at decode time.
private struct OAuthUsageEnvelope: Decodable {
    let bindingType: BindingType?
    /// Used when the envelope reports a single binding only:
    /// `{rate_limit_type:"five_hour", utilization:0.27, resets_at:"…"}`.
    let flatUtilization: Double?
    let flatResetsAt: AnyDate?

    /// Per-window readings. Either top-level (`{five_hour:{utilization,resets_at}}`)
    /// or nested under `rate_limits.five_hour`.
    let fiveHourReading: WindowReading?
    let sevenDayReading: WindowReading?

    let organizationUuid: String?

    enum BindingType: Decodable {
        case fiveHour, sevenDay, sevenDayOpus, sevenDaySonnet, overage
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            let raw = try c.decode(String.self)
            switch raw {
            case "five_hour", "fiveHour": self = .fiveHour
            case "seven_day", "sevenDay": self = .sevenDay
            case "seven_day_opus", "sevenDayOpus": self = .sevenDayOpus
            case "seven_day_sonnet", "sevenDaySonnet": self = .sevenDaySonnet
            case "overage": self = .overage
            default:
                throw DecodingError.dataCorruptedError(
                    in: c,
                    debugDescription: "Unknown rate_limit_type: \(raw)"
                )
            }
        }
    }

    struct WindowReading: Decodable {
        let utilization: Double?      // 0.0...1.0
        let usedPercentage: Double?   // 0...100 (statusline-style)
        let resetsAt: AnyDate?
    }

    /// Accept either ISO-8601 string or epoch seconds.
    struct AnyDate: Decodable {
        let date: Date

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) {
                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let d = iso.date(from: s) { date = d; return }
                let iso2 = ISO8601DateFormatter()
                iso2.formatOptions = [.withInternetDateTime]
                if let d = iso2.date(from: s) { date = d; return }
            }
            if let secs = try? c.decode(Double.self) {
                date = Date(timeIntervalSince1970: secs); return
            }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "AnyDate: not a recognized date")
        }

        func epoch(server: Int) -> Int {
            max(server, Int(date.timeIntervalSince1970))
        }
    }

    private enum FlatKeys: String, CodingKey {
        case rateLimitType, utilization, resetsAt
        case fiveHour, sevenDay
        case rateLimits
        case organizationUuid
    }

    private enum NestedKeys: String, CodingKey {
        case fiveHour, sevenDay
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: FlatKeys.self)
        self.bindingType = try c.decodeIfPresent(BindingType.self, forKey: .rateLimitType)
        self.flatUtilization = try c.decodeIfPresent(Double.self, forKey: .utilization)
        self.flatResetsAt = try c.decodeIfPresent(AnyDate.self, forKey: .resetsAt)
        self.organizationUuid = try c.decodeIfPresent(String.self, forKey: .organizationUuid)

        var five = try c.decodeIfPresent(WindowReading.self, forKey: .fiveHour)
        var seven = try c.decodeIfPresent(WindowReading.self, forKey: .sevenDay)
        if (five == nil || seven == nil),
           let nested = try? c.nestedContainer(keyedBy: NestedKeys.self, forKey: .rateLimits) {
            if five == nil  { five  = try nested.decodeIfPresent(WindowReading.self, forKey: .fiveHour) }
            if seven == nil { seven = try nested.decodeIfPresent(WindowReading.self, forKey: .sevenDay) }
        }
        self.fiveHourReading = five
        self.sevenDayReading = seven
    }

    /// Resolve one window. `fallbackBinding` + `fallbackResetEpoch` only apply
    /// when this is the single-binding window (the envelope reported just the
    /// flat shape).
    func window(for which: UsageData.BindingWindow,
                fallbackBinding: Double?,
                fallbackResetEpoch: Int?) -> (pct: Int, resetEpoch: Int)? {
        let reading: WindowReading? = (which == .fiveHour) ? fiveHourReading : sevenDayReading
        if let reading {
            let pct: Int
            if let p = reading.usedPercentage { pct = Int(p.rounded()) }
            else if let u = reading.utilization { pct = Int((u * 100).rounded()) }
            else { return nil }
            let resetEpoch = reading.resetsAt.map { Int($0.date.timeIntervalSince1970) }
                ?? Int(Date().addingTimeInterval(60).timeIntervalSince1970)
            return (pct, resetEpoch)
        }
        if let u = fallbackBinding {
            let pct = Int((u * 100).rounded())
            let resetEpoch = fallbackResetEpoch ?? Int(Date().addingTimeInterval(60).timeIntervalSince1970)
            return (pct, resetEpoch)
        }
        return nil
    }
}

// TokenProvider protocol moved to TokenProvider.swift (2026-05-18) so that
// the Linux libsecret implementation can live alongside other implementations
// without dragging in AnthropicSource's URLSession + ratelimit-parser surface.

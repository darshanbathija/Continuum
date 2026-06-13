import Foundation
#if canImport(OSLog)
import OSLog
#endif

private let logger = Logger(subsystem: "com.clawdmeter.shared", category: "AnthropicSource")

/// V1 `AISource` implementation against the Phase 0 Data Source Contract.
///
/// **Primary path:** `GET /api/oauth/usage`, the non-generative endpoint
/// `claude` itself uses for its rate-limit fetch. Earlier builds used a
/// 1-token `/v1/messages` request to read unified rate-limit headers, but that
/// created visible throwaway Claude conversations and consumed quota on every
/// poll. Usage polling must never generate model output.
///
/// The `/api/oauth/usage` response body's `rate_limit_type` / `utilization` /
/// `resets_at` is enough to populate the binding window, with the un-binding
/// window remembered from the previous successful poll when the endpoint
/// returns only one window. If Anthropic expands the endpoint to return both
/// windows, `OAuthUsageEnvelope` already consumes those richer shapes.
public final class AnthropicSource: AISource, @unchecked Sendable {

    public let providerID = "anthropic"
    public let displayName = "Claude (Anthropic)"

    private let tokenProvider: TokenProvider
    private let urlSession: URLSession
    private let oauthUsageEndpoint: URL
    private let userAgent: String

    /// Bounded refresh attempts per E7. Use a window to prevent infinite retries.
    private var refreshAttempts: [Date] = []
    private let refreshWindowSeconds: TimeInterval = 600 // 10 min
    private let maxRefreshAttemptsPerWindow = 2

    /// Latest window snapshots, kept across polls so the un-binding window's
    /// percentage doesn't drop to 0% when the OAuth usage API only reports the
    /// binding window. Richer response shapes override both windows on every
    /// successful poll.
    private var lastSession: (pct: Int, resetEpoch: Int)?
    private var lastWeekly: (pct: Int, resetEpoch: Int)?

    public init(
        tokenProvider: TokenProvider,
        urlSession: URLSession? = nil,
        messagesEndpoint: URL = URL(string: "https://api.anthropic.com/api/oauth/usage")!,
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
            #if canImport(Darwin)
            cfg.waitsForConnectivity = false
            #endif
            self.urlSession = URLSession(configuration: cfg)
        }
        // Source compatibility: older callers may still pass this argument,
        // but usage polling no longer posts to /v1/messages.
        _ = messagesEndpoint
        self.oauthUsageEndpoint = oauthUsageEndpoint
        _ = ccVersion
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
        logger.info("AnthropicSource.poll: authenticated; trying /api/oauth/usage")
        defer { logger.info("AnthropicSource.poll: HTTPS leg done") }
        return try await pollOAuthUsage(token: token)
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

    // MARK: - Primary path (/api/oauth/usage + JSON body)

    /// Parse RFC 7231 `date:` header into a `Date`.
    private func parseServerDate(from response: HTTPURLResponse) -> Date? {
        guard let raw = response.value(forHTTPHeaderField: "date") else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: raw)
    }

    private func pollOAuthUsage(token: String) async throws -> UsageData {
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
            logger.info("AnthropicSource.parseOAuthUsageBody: decode body bytes=\(data.count, privacy: .public)")
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
    /// `{rate_limit_type:"five_hour", utilization:27, resets_at:"…"}`.
    /// `utilization` is a percentage (0...100), same as the nested shape —
    /// see `WindowReading`; it is NOT a 0...1 fraction.
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
        // Both fields are PERCENTAGE units (0...100), NOT 0...1 fractions.
        // `utilization` is empirically confirmed against the live
        // `/api/oauth/usage` (`five_hour: 8.0` = 8%, `seven_day: 1.0` = 1%);
        // `usedPercentage` is the statusline contract's documented 0...100
        // value. Do not reintroduce a fraction (×100) heuristic for either —
        // see the percent-scaling note in `window(...)`.
        let utilization: Double?      // 0...100 (empirically confirmed)
        let usedPercentage: Double?   // 0...100 (statusline contract)
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
            max(server, OAuthUsageEnvelope.safeEpoch(date))
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
        // `utilization` and `used_percentage` are both percentages (0...100).
        // A previous "value <= 1 ⇒ a 0...1 fraction, multiply by 100" heuristic
        // mis-scaled genuine sub-1% usage: a weekly `utilization` of 1.0 (1%
        // used) became 100%, pinning the gauge. Treat every reading as a
        // percentage and only clamp/round.
        let reading: WindowReading? = (which == .fiveHour) ? fiveHourReading : sevenDayReading
        if let reading {
            let pct: Int
            if let p = reading.usedPercentage { pct = Self.clampPercent(p) }
            else if let u = reading.utilization { pct = Self.clampPercent(u) }
            else { return nil }
            let resetEpoch = reading.resetsAt.map { Self.safeEpoch($0.date) }
                ?? Int(Date().addingTimeInterval(60).timeIntervalSince1970)
            return (pct, resetEpoch)
        }
        if let u = fallbackBinding {
            let pct = Self.clampPercent(u)
            let resetEpoch = fallbackResetEpoch ?? Int(Date().addingTimeInterval(60).timeIntervalSince1970)
            return (pct, resetEpoch)
        }
        return nil
    }

    private static func clampPercent(_ value: Double) -> Int {
        // Clamp as a Double BEFORE the Int conversion, and reject non-finite
        // inputs. `Int(_:)` TRAPS (app-wide crash) on NaN/±Inf or a
        // finite-but-huge Double > Int.max — a garbage or MITM'd
        // `/api/oauth/usage` body could otherwise crash the poller's task and
        // take the whole process down. After this, Int() only ever sees 0...100.
        guard value.isFinite else { return 0 }
        return Int(min(100, max(0, value.rounded())))
    }

    /// Safe `Date` → epoch-seconds for an untrusted `resets_at`. A garbage or
    /// MITM'd timestamp (NaN, ±Inf, or absurdly large) would otherwise trap
    /// `Int(_:)` the same way the huge-`utilization` path did and crash the
    /// poller's task. Out-of-range values collapse to 0, so the caller's
    /// `max(server, …)` / reset-minutes math degrades to "no countdown"
    /// instead of crashing. 4_102_444_800 = 2100-01-01 (well under Int.max).
    static func safeEpoch(_ date: Date) -> Int {
        let ti = date.timeIntervalSince1970
        guard ti.isFinite, ti >= 0, ti < 4_102_444_800 else { return 0 }
        return Int(ti)
    }
}

// TokenProvider protocol moved to TokenProvider.swift (2026-05-18) so token
// implementations can live outside AnthropicSource's URLSession + rate-limit
// parser surface.

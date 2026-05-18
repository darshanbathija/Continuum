import Foundation
import OSLog

private let logger = Logger(subsystem: "com.clawdmeter.shared", category: "AnthropicSource")

/// `AISource` implementation that fetches Claude.ai subscription usage from
/// the same `GET /api/oauth/usage` endpoint Claude Code uses internally.
///
/// **Why this endpoint, not `/v1/messages`?** Before v0.4.11 we hit `POST
/// /v1/messages` with a 1-token request and parsed the `anthropic-ratelimit-
/// unified-*` response headers. That worked for months — until Anthropic
/// tightened the OAuth surface on `/v1/messages` to block Pro/Max OAuth
/// tokens (response: HTTP 403 `permission_error` "OAuth authentication is
/// currently not allowed for this organization"). The user-visible symptom
/// was the Mac dashboard sitting on "Connecting…" forever. `claude` CLI
/// itself still works because it goes through `/api/oauth/usage` for the
/// rate-limit fetch — discovered by searching `~/.local/bin/claude` for
/// `fetchUtilization: GET /api/oauth/usage`. We now match that path.
///
/// **Response shape (observed via binary strings and the statusline doc):**
/// either a single representative-claim object
/// ```json
/// {"rate_limit_type":"five_hour","utilization":0.27,"resets_at":"<ISO 8601>"}
/// ```
/// or a richer multi-window envelope
/// ```json
/// {"five_hour":{"utilization":0.27,"resets_at":"<ISO>"},
///  "seven_day":{"utilization":0.42,"resets_at":"<ISO>"},
///  "rate_limit_type":"seven_day"}
/// ```
/// or a `{rate_limits:{five_hour:…,seven_day:…}}` envelope matching what
/// `claude` itself feeds the statusline. We decode all three shapes; whichever
/// turns out to be authoritative will fill `UsageData` cleanly.
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

    /// Latest window snapshots, kept across polls so that the un-binding
    /// window's percentage doesn't drop to 0% on each tick (the API may only
    /// report the binding window when the other is fresh / unused).
    private var lastSession: (pct: Int, resetEpoch: Int)?
    private var lastWeekly: (pct: Int, resetEpoch: Int)?

    public init(
        tokenProvider: TokenProvider,
        urlSession: URLSession? = nil,
        endpoint: URL = URL(string: "https://api.anthropic.com/api/oauth/usage")!,
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
        logger.info("AnthropicSource.poll: token len=\(token.count) fp=\(fp, privacy: .public), GET \(self.endpoint, privacy: .public)")
        defer { logger.info("AnthropicSource.poll: HTTPS leg done") }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // The oauth-2025-04-20 beta gates the OAuth-mode endpoints. Belt-and-
        // suspenders: Claude Code's own request includes it even on /api/* paths.
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

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
            return try parseUsage(body: result.data, response: http)
        case 401, 403:
            // Auth chain handled in poller's bounded-retry wrapper (E7).
            // 403 with `OAuth authentication is currently not allowed` was
            // the v0.4.10-era symptom that pushed us off /v1/messages.
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

    // MARK: - Response parsing

    /// Defensive decoder. The `/api/oauth/usage` response shape isn't
    /// publicly documented; reverse-engineered from `claude` CLI's bundled
    /// JS. We try the richer shape first, fall back to the single-binding
    /// shape, and as a last resort try the `{rate_limits:{…}}` envelope.
    private func parseUsage(body: Data, response: HTTPURLResponse) throws -> UsageData {
        let serverDate = parseServerDate(from: response) ?? Date()
        let serverEpoch = Int(serverDate.timeIntervalSince1970)

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let envelope: OAuthUsageEnvelope
        do {
            envelope = try decoder.decode(OAuthUsageEnvelope.self, from: body)
        } catch {
            logger.error("AnthropicSource.parseUsage: JSON decode failed: \(error.localizedDescription, privacy: .public)")
            // Dump a short preview of the body so we can shape-correct in v0.4.12.
            let preview = String(data: body.prefix(400), encoding: .utf8) ?? "<binary>"
            logger.info("AnthropicSource.parseUsage: body preview: \(preview, privacy: .public)")
            throw AISourceError.malformedResponse(detail: "Could not decode /api/oauth/usage body")
        }

        // Resolve the binding window per Claude Code's own taxonomy.
        let binding: UsageData.BindingWindow = {
            switch envelope.bindingType {
            case .fiveHour: return .fiveHour
            case .sevenDay, .sevenDayOpus, .sevenDaySonnet: return .sevenDay
            case .overage, .none: return .unknown
            }
        }()

        // Pull the two window snapshots. Each one of these can come from:
        //   1) a nested object on the envelope ({"five_hour":{…}})
        //   2) the single-binding shape (`utilization` on the root maps to
        //      whichever window `rateLimitType` names)
        //   3) the previous tick's cached value (so the unbinding window
        //      doesn't reset to 0% just because the API stopped reporting it)
        let session = envelope.window(for: .fiveHour, fallbackBinding: binding == UsageData.BindingWindow.fiveHour ? envelope.flatUtilization : nil,
                                       fallbackResetEpoch: binding == UsageData.BindingWindow.fiveHour ? envelope.flatResetsAt?.epoch(server: serverEpoch) : nil)
        let weekly = envelope.window(for: .sevenDay, fallbackBinding: binding == UsageData.BindingWindow.sevenDay ? envelope.flatUtilization : nil,
                                      fallbackResetEpoch: binding == UsageData.BindingWindow.sevenDay ? envelope.flatResetsAt?.epoch(server: serverEpoch) : nil)

        let sessionPct = session?.pct ?? lastSession?.pct ?? 0
        let sessionEpoch = session?.resetEpoch ?? lastSession?.resetEpoch ?? serverEpoch
        let weeklyPct = weekly?.pct ?? lastWeekly?.pct ?? 0
        let weeklyEpoch = weekly?.resetEpoch ?? lastWeekly?.resetEpoch ?? serverEpoch

        // Remember the freshest readings so the next poll keeps the unbinding
        // window stable rather than dropping to 0%.
        if let session { lastSession = session }
        if let weekly { lastWeekly = weekly }

        let sessionResetMins = max(0, (sessionEpoch - serverEpoch) / 60)
        let weeklyResetMins = max(0, (weeklyEpoch - serverEpoch) / 60)

        // Status: "limited" if either window is fully consumed.
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

// MARK: - Envelope

/// Catch-all decoder for the `/api/oauth/usage` response. Tolerates three
/// observed-or-inferred shapes by making every field optional and unifying
/// the candidate locations at decode time.
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

    enum BindingType: String, Decodable {
        // The Decoder uses `.convertFromSnakeCase`, but enum raw values
        // are matched verbatim against the original (post-conversion)
        // string. So "five_hour" on the wire decodes after the strategy
        // turns it into "fiveHour" — we accept either casing here so
        // the strategy choice and the wire shape stay decoupled.
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
                if let d = iso.date(from: s) {
                    date = d; return
                }
                let iso2 = ISO8601DateFormatter()
                iso2.formatOptions = [.withInternetDateTime]
                if let d = iso2.date(from: s) {
                    date = d; return
                }
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
        case rateLimitType
        case utilization
        case resetsAt
        case fiveHour
        case sevenDay
        case rateLimits      // nested envelope: {"rate_limits":{"five_hour":…, "seven_day":…}}
        case organizationUuid
    }

    private enum NestedKeys: String, CodingKey {
        case fiveHour
        case sevenDay
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: FlatKeys.self)
        self.bindingType = try c.decodeIfPresent(BindingType.self, forKey: .rateLimitType)
        self.flatUtilization = try c.decodeIfPresent(Double.self, forKey: .utilization)
        self.flatResetsAt = try c.decodeIfPresent(AnyDate.self, forKey: .resetsAt)
        self.organizationUuid = try c.decodeIfPresent(String.self, forKey: .organizationUuid)

        // Try the multi-window shapes.
        var five = try c.decodeIfPresent(WindowReading.self, forKey: .fiveHour)
        var seven = try c.decodeIfPresent(WindowReading.self, forKey: .sevenDay)
        if five == nil || seven == nil,
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

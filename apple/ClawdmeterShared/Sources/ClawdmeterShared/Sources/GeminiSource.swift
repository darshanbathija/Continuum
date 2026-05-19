#if os(macOS)
import Foundation
import OSLog

/// `AISource` against Google's Cloud Code Assist Public API — the same
/// endpoint Antigravity polls every ~5 minutes for its per-model quota bars.
///
/// **Endpoint**: `POST https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist`
///
/// **Auth**: `Authorization: Bearer <access_token>` using the user's existing
/// Gemini CLI OAuth token at `~/.gemini/oauth_creds.json` (read by
/// `GeminiTokenProvider`). The token has `cloud-platform` scope, which the
/// `gemini auth login` flow grants by default.
///
/// **Response shape** (inferred from Antigravity's bundled JS + the
/// `loadCodeAssist` log frames in `~/Library/Application Support/Antigravity/logs/`;
/// EMPIRICAL CONFIRMATION needed on first run):
/// ```json
/// {
///   "currentTier": { "id": "free" | "paid" | ... },
///   "userModelQuotas": [
///     {
///       "modelName": "gemini-3.1-pro-high",
///       "usedQuota": 247,
///       "quotaLimit": 1000,
///       "refreshTime": "2026-05-19T12:00:00Z",
///       "refreshWindowMinutes": 300
///     },
///     ...
///   ]
/// }
/// ```
///
/// **Parser strategy**: This source is deliberately *tolerant* of field-name
/// drift. We try a small set of likely field names per role (`modelQuotas`,
/// `userModelQuotas`, `quotas`) and log which combination matched so the
/// first real-world poll surfaces the actual shape. If parsing fails, the
/// D7 cached-stale-badge fallback engages.
///
/// **TOS posture**: `v1internal:*` is not a public API. We accept the same
/// risk class as `CodexSource` against `chatgpt.com/backend-api/wham/usage`.
/// Document in PR body + CLAUDE.md.
public final class GeminiSource: AISource, @unchecked Sendable {

    public let providerID = "gemini"
    public let displayName = "Gemini"

    private let tokenProvider: TokenProvider
    private let urlSession: URLSession
    private let endpoint: URL
    private let logger = Logger(subsystem: "com.clawdmeter.shared", category: "GeminiSource")

    /// D7 cached-fallback state — last successful per-model bucket. Mirrors
    /// `AnthropicSource.lastSession` / `.lastWeekly`. On parse failure or
    /// 5xx, we return this with `.unknown` status so the UI renders a
    /// stale-but-honest snapshot instead of going blank.
    private var lastSession: (pct: Int, resetEpoch: Int)?
    private var lastWeekly: (pct: Int, resetEpoch: Int)?
    private var lastUpdatedAt: Date?

    public init(
        tokenProvider: TokenProvider,
        urlSession: URLSession? = nil,
        endpoint: URL = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!
    ) {
        self.tokenProvider = tokenProvider
        self.endpoint = endpoint
        if let urlSession {
            self.urlSession = urlSession
        } else {
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 8
            cfg.timeoutIntervalForResource = 12
            cfg.waitsForConnectivity = false
            // Per-source URLSession to avoid the macOS Tahoe URLSession.shared
            // hang issue documented in AnthropicSource:70-78.
            self.urlSession = URLSession(configuration: cfg)
        }
    }

    public var isAuthenticated: Bool {
        // GeminiTokenProvider extends with `isTokenExpired` separately —
        // the UsagePoller will surface `.unauthenticated` for both no-token
        // and expired-token paths, and the D4 dashboard UI distinguishes
        // by also checking `(provider as? GeminiTokenProvider)?.isTokenExpired`.
        guard tokenProvider.hasToken else { return false }
        if let geminiProvider = tokenProvider as? GeminiTokenProvider {
            return !geminiProvider.isTokenExpired
        }
        return true
    }

    public func refreshCredentialsIfNeeded() async throws -> Bool {
        try await tokenProvider.refreshIfNeeded()
    }

    public func poll() async throws -> UsageData {
        guard let token = tokenProvider.currentAccessToken else {
            throw AISourceError.unauthenticated
        }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        // Antigravity-style user agent; some Google endpoints gate on
        // recognized clients.
        req.setValue("Clawdmeter/1.0 (+gemini-compat)", forHTTPHeaderField: "User-Agent")
        // Empty JSON body — Antigravity sends a small protobuf payload via
        // gRPC-Web; the JSON Connect-protocol equivalent accepts `{}`.
        req.httpBody = Data("{}".utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: req)
        } catch {
            logger.warning("Gemini poll network error: \(String(describing: error), privacy: .public)")
            return try cachedFallbackOrThrow(reason: "network")
        }

        guard let http = response as? HTTPURLResponse else {
            return try cachedFallbackOrThrow(reason: "non-http")
        }

        switch http.statusCode {
        case 200:
            if let usage = parseLoadCodeAssistResponse(data) {
                return usage
            }
            let preview = String(data: data.prefix(500), encoding: .utf8) ?? "<binary>"
            logger.warning("Gemini parse miss; body preview: \(preview, privacy: .public)")
            return try cachedFallbackOrThrow(reason: "parse-miss")
        case 401, 403:
            // Stale or rejected token — surface as unauthenticated so the
            // UsagePoller's refresh path picks up a rotation by `gemini auth
            // login`. D4 stale-token UX runs in the UI layer when the
            // expiry_date in oauth_creds.json is in the past.
            throw AISourceError.unauthenticated
        case 429:
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw AISourceError.rateLimited(retryAfter: retryAfter)
        case 500...599:
            return try cachedFallbackOrThrow(reason: "5xx")
        default:
            return try cachedFallbackOrThrow(reason: "unexpected-\(http.statusCode)")
        }
    }

    // MARK: - Parser

    /// Tolerant decoder. Tries the field name combinations Antigravity's
    /// bundled JS hints at; on first real-world poll, the logs above will
    /// surface the actual shape and we refine.
    private func parseLoadCodeAssistResponse(_ data: Data) -> UsageData? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        // Try known field-name candidates for the per-model quota array.
        let modelBuckets: [[String: Any]]? = {
            for key in ["userModelQuotas", "modelQuotas", "quotas", "userQuotas"] {
                if let arr = root[key] as? [[String: Any]], !arr.isEmpty { return arr }
            }
            return nil
        }()
        guard let buckets = modelBuckets else { return nil }

        // Filter to gemini-* models, pick the WORST (highest used pct).
        // Mirrors CodexSource's "show me the most constrained bucket"
        // approach — what Antigravity's UI displays as the headline gauge.
        var bestSession: (pct: Int, resetEpoch: Int)?
        for raw in buckets {
            let modelName: String = (raw["modelName"] as? String)
                ?? (raw["name"] as? String)
                ?? (raw["id"] as? String)
                ?? ""
            guard modelName.lowercased().hasPrefix("gemini") else { continue }

            let used: Double = (raw["usedQuota"] as? Double)
                ?? (raw["used"] as? Double)
                ?? Double(raw["usedQuota"] as? Int ?? 0)
            let limit: Double = (raw["quotaLimit"] as? Double)
                ?? (raw["limit"] as? Double)
                ?? Double(raw["quotaLimit"] as? Int ?? 0)
            guard limit > 0 else { continue }
            let pct = Int((used / limit * 100).rounded())

            let resetEpoch = Self.parseResetTime(raw)

            if let cur = bestSession, pct < cur.pct { continue }
            bestSession = (pct, resetEpoch)
        }

        guard let session = bestSession else { return nil }

        let now = Date()
        let nowEpoch = Int(now.timeIntervalSince1970)
        let sessionMins = max(0, (session.resetEpoch - nowEpoch + 59) / 60)

        // Weekly bucket: cloudcode-pa quotas are 5h-bucketed in Antigravity's
        // UI, but a "weekly" concept doesn't surface in the loadCodeAssist
        // response we can see. Leave weeklyPct = 0 + weeklyResetMins = 7d
        // for now; future iteration can pull from a separate billing endpoint
        // if we discover one.
        lastSession = session
        lastUpdatedAt = now

        let weeklyEpoch = nowEpoch + 7 * 24 * 3600
        let weeklyMins = 7 * 24 * 60

        return UsageData(
            sessionPct: session.pct,
            sessionResetMins: sessionMins,
            sessionEpoch: session.resetEpoch,
            weeklyPct: lastWeekly?.pct ?? 0,
            weeklyResetMins: weeklyMins,
            weeklyEpoch: lastWeekly?.resetEpoch ?? weeklyEpoch,
            status: session.pct >= 100 ? .limited : .allowed,
            representativeClaim: .fiveHour,
            updatedAt: now
        )
    }

    /// Parse the per-bucket reset time. Try ISO 8601 first (Antigravity's
    /// log frames), then epoch seconds / millis.
    private static func parseResetTime(_ raw: [String: Any]) -> Int {
        for key in ["refreshTime", "resetAt", "resetsAt", "resetTime"] {
            if let s = raw[key] as? String {
                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let d = iso.date(from: s) { return Int(d.timeIntervalSince1970) }
                let iso2 = ISO8601DateFormatter()
                iso2.formatOptions = [.withInternetDateTime]
                if let d = iso2.date(from: s) { return Int(d.timeIntervalSince1970) }
            }
            if let n = raw[key] as? Int {
                // Heuristic: epoch millis vs seconds.
                return n > 10_000_000_000 ? n / 1000 : n
            }
            if let d = raw[key] as? Double {
                return d > 10_000_000_000 ? Int(d / 1000) : Int(d)
            }
        }
        // Fallback: assume a 5h window from now.
        return Int(Date().timeIntervalSince1970) + 5 * 3600
    }

    /// D7 fallback. When cloudcode-pa parsing fails, return the last good
    /// snapshot with `.unknown` status so the UI renders cached data + a
    /// "Updated Nh ago" stale badge instead of going blank.
    /// Return a cached snapshot if available, otherwise throw so the
    /// UsagePoller leaves `model.usage` at nil → UI renders "Connecting…"
    /// instead of a misleading "0% now" / 26-secs-from-now countdown.
    /// Critical: returning a placeholder UsageData with `sessionEpoch ==
    /// nowEpoch` caused the popover to perpetually tick from "26 secs"
    /// down to "now" on each 60s poll — visually "the countdown isn't
    /// working" because the reset target kept moving with the current
    /// time.
    private func cachedFallbackOrThrow(reason: String) throws -> UsageData {
        let now = Date()
        let nowEpoch = Int(now.timeIntervalSince1970)
        if let last = lastSession, let updated = lastUpdatedAt {
            // Have a previous good poll — render its data with a stale
            // status badge per D7.
            let mins = max(0, (last.resetEpoch - nowEpoch + 59) / 60)
            return UsageData(
                sessionPct: last.pct,
                sessionResetMins: mins,
                sessionEpoch: last.resetEpoch,
                weeklyPct: lastWeekly?.pct ?? 0,
                weeklyResetMins: 7 * 24 * 60,
                weeklyEpoch: lastWeekly?.resetEpoch ?? nowEpoch + 7 * 24 * 3600,
                status: .unknown,
                representativeClaim: .unknown,
                updatedAt: updated
            )
        }
        // No cache — throw so the UI keeps showing "Connecting…" (a
        // honest "no data yet" rather than a fabricated 0% gauge). The
        // poller will retry on its next 60s tick.
        logger.info("Gemini fallback no-cache: reason=\(reason, privacy: .public); surfacing as dataSourceContractViolation so UI shows Connecting…")
        throw AISourceError.dataSourceContractViolation(
            detail: "Gemini first-poll \(reason) — no cached usage yet, UI stays at Connecting…"
        )
    }
}
#endif

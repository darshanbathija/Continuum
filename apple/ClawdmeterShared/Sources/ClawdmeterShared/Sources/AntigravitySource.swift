#if os(macOS)
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(OSLog)
import OSLog
#endif

/// `AISource` against Antigravity 2's quota surface. v0.8.0 implements
/// the 3-tier fallback ladder Phase 0/0.5 designed (D9):
///
///   1. **LS-local**: `POST http://127.0.0.1:<httpPort>/v1internal:fetchUserInfo`
///      against the running `language_server`. Same endpoint Antigravity
///      itself uses, so it reflects the freshest quota state. The exact
///      response shape was untested in Phase 0 (docs/agentapi-event-catalog.md
///      notes it as "v0.8.1's AntigravitySource rewrite tests this directly");
///      v0.8.0 treats it as optimistic-first — any failure falls through
///      to tier 2 silently.
///   2. **Cloud public**: `POST https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota`
///      with the user's OAuth token. The v0.7 path, preserved here as the
///      reliable production tier — works regardless of whether Antigravity.app
///      is running, requires a valid local OAuth credential at
///      `~/.gemini/oauth_creds.json` (read by `GeminiTokenProvider`).
///   3. **Empty**: neither tier succeeded — return a stale-but-honest
///      placeholder via `cachedFallbackOrThrow` so the dashboard renders
///      the "Open Antigravity 2 to see usage" CTA next to the empty gauge.
///
/// Renamed from `GeminiSource` in v0.8.0 (file rename + class rename);
/// the wire-level `providerID` key STAYS `"gemini"` in v0.8.0 so iOS/Watch
/// clients on older wire versions keep decoding usage payloads via the
/// dual-key bridge (`Protocol.UsageEnvelope.usageData(for:)`). v0.8.1
/// renames `displayName` to "Antigravity" once the iOS/Watch labels also
/// swap over (T12 cosmetic sweep).
///
/// ## Original cloudcode-pa endpoint contract (preserved verbatim from v0.7)
///
/// **Endpoint**: `POST https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota`
/// with body `{"project": "<projectId>"}`. The endpoint name + request +
/// response shape are taken verbatim from the open-source `gemini` CLI
/// (homebrew install at `/opt/homebrew/Cellar/gemini-cli/0.42.0/.../chunk-DN4XSYRG.js`,
/// search `retrieveUserQuota`):
///
/// ```typescript
/// // Request:
/// { project: codeAssistServer.projectId }  // may be null for personal-OAuth users
///
/// // Response (returned by the server, parsed by gemini CLI's bucket loop):
/// {
///   buckets: [
///     {
///       modelId: "gemini-3-pro",        // or "gemini-3-flash" etc.
///       remainingAmount: "247",         // string per the proto; parseInt at consume time
///       remainingFraction: 0.247,       // 0.0 - 1.0
///       resetTime: "2026-05-19T13:00:00Z"
///     },
///     ...
///   ]
/// }
/// ```
///
/// gemini CLI computes used% as `(1 - remainingFraction) * 100` and limit
/// as `remainingAmount / remainingFraction` when `remainingAmount` is
/// present (else falls back to limit=100, remaining=fraction*100).
///
/// **Auth**: `Authorization: Bearer <access_token>` using the user's
/// existing Gemini CLI OAuth token at `~/.gemini/oauth_creds.json` (read
/// by `GeminiTokenProvider`). Token has `cloud-platform` scope which
/// `gemini auth login` grants by default.
///
/// **Optional pre-call to loadCodeAssist**: When the user has a paid GCP
/// project (oauth + `gcloud config set project`), gemini CLI first hits
/// `loadCodeAssist` to discover `cloudaicompanionProject` and pass that
/// as `project` on retrieveUserQuota. For personal-OAuth users (the
/// `auth.selectedType == "oauth-personal"` case in `~/.gemini/settings.json`)
/// projectId is null and the call still works — the server returns the
/// user's personal-tier buckets. We try retrieveUserQuota directly with
/// an empty project first; if 400/403 hint at "project required", we
/// fall through to the loadCodeAssist discovery path.
///
/// **TOS posture**: `v1internal:*` is an internal Google API surface; we
/// accept the same risk class as `CodexSource` against
/// `chatgpt.com/backend-api/wham/usage`. Document in PR body + CLAUDE.md.
public final class AntigravitySource: AISource, @unchecked Sendable {

    // v0.8.0 keeps the wire-level providerID as "gemini" for back-compat
    // with v8/v9 clients. Renamed to "antigravity" in v0.8.1 once iOS/Watch
    // labels also update; the dual-key bridge in Protocol.UsageEnvelope
    // handles the migration.
    public let providerID = "gemini"
    public let displayName = "Gemini"

    private let tokenProvider: TokenProvider
    private let urlSession: URLSession
    private let quotaEndpoint: URL
    private let loadCodeAssistEndpoint: URL
    private let logger = Logger(subsystem: "com.clawdmeter.shared", category: "AntigravitySource")

    /// Cached after the first successful `loadCodeAssist` so we don't
    /// re-discover the project on every 60s poll. `nil` for personal-OAuth
    /// users who don't have a GCP project.
    private var cachedProjectId: String?

    /// D7 cached-fallback state — last successful per-model bucket.
    /// On parse failure or 5xx, return this with `.unknown` status so the
    /// UI renders a stale-but-honest snapshot instead of going blank.
    private var lastSession: (pct: Int, resetEpoch: Int)?
    private var lastWeekly: (pct: Int, resetEpoch: Int)?
    private var lastUpdatedAt: Date?

    /// v0.6.0: Antigravity 2 adds the `daily-cloudcode-pa.googleapis.com`
    /// host alongside the legacy `cloudcode-pa.googleapis.com`. We try
    /// the daily host first (fresher quota model for daily-channel users
    /// the live Antigravity Electron app prefers), fall back to legacy
    /// on 404/5xx. Cached per-host last-good state means subsequent polls
    /// stick to whichever host responded successfully last.
    private let dailyQuotaEndpoint: URL
    private var preferredQuotaHost: URL?  // nil = try daily first

    /// v0.8.0 D9 tier-1 probe — looks up a live Antigravity language_server
    /// on every poll (~50ms via pgrep+lsof+ps). Nil means we skip the
    /// LS-local tier entirely and go straight to cloudcode-pa. Tests
    /// inject a custom closure to verify both branches.
    public typealias LSQuotaProbe = @Sendable () async -> UsageData?
    private let lsQuotaProbe: LSQuotaProbe?

    public init(
        tokenProvider: TokenProvider,
        urlSession: URLSession? = nil,
        quotaEndpoint: URL = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")!,
        dailyQuotaEndpoint: URL = URL(string: "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")!,
        loadCodeAssistEndpoint: URL = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!,
        lsQuotaProbe: LSQuotaProbe? = nil
    ) {
        self.tokenProvider = tokenProvider
        self.quotaEndpoint = quotaEndpoint
        self.dailyQuotaEndpoint = dailyQuotaEndpoint
        self.loadCodeAssistEndpoint = loadCodeAssistEndpoint
        self.lsQuotaProbe = lsQuotaProbe
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
        // v0.8.0 D9 tier-1: try LS-local /v1internal:fetchUserInfo first.
        // The probe runs ~50ms (pgrep+lsof+ps + HTTPS round-trip on a
        // loopback port), but caches nothing — D13 always re-discovers.
        // When Antigravity.app isn't running, this returns nil silently.
        if let probe = lsQuotaProbe, let usage = await probe() {
            return usage
        }

        // Tier 2: v0.7's cloudcode-pa path. Requires the user's OAuth
        // credential at ~/.gemini/oauth_creds.json — same path Antigravity 2
        // writes when the user signs in.
        guard let token = tokenProvider.currentAccessToken else {
            throw AISourceError.unauthenticated
        }

        // Step 1: try retrieveUserQuota directly. For personal-OAuth users
        // we don't need a project at all; for paid tier we'll need to
        // call loadCodeAssist first to discover the project.
        let projectToTry = cachedProjectId ?? ""
        do {
            let usage = try await callRetrieveUserQuota(token: token, project: projectToTry)
            return usage
        } catch AISourceError.dataSourceContractViolation(let detail) where detail.contains("needs-project") {
            // Server wants a project ID we don't have yet — discover it.
            logger.info("Antigravity retrieveUserQuota indicated needs-project; calling loadCodeAssist to discover")
            let discovered = try await discoverProjectIdViaLoadCodeAssist(token: token)
            self.cachedProjectId = discovered
            return try await callRetrieveUserQuota(token: token, project: discovered)
        }
    }

    // MARK: - retrieveUserQuota

    private func callRetrieveUserQuota(token: String, project: String) async throws -> UsageData {
        // v0.6.0 dual-host: prefer daily-cloudcode-pa (fresher channel
        // Antigravity 2 uses); fall back to legacy cloudcode-pa on 404/5xx.
        // Cached `preferredQuotaHost` skips the daily attempt once we know
        // it failed, so we don't slow every poll with a fail-then-fallback
        // round-trip.
        let primary = preferredQuotaHost ?? dailyQuotaEndpoint
        let secondary = (primary == quotaEndpoint) ? dailyQuotaEndpoint : quotaEndpoint
        do {
            let usage = try await callRetrieveUserQuota(token: token, project: project, endpoint: primary)
            preferredQuotaHost = primary // remember good host
            return usage
        } catch let e as AISourceError where {
            switch e {
            case .dataSourceContractViolation, .unauthenticated, .rateLimited: return true
            default: return false
            }
        }() {
            // These errors aren't host-related — re-throw without trying
            // the secondary (auth/rate-limit/contract-failure means the
            // server understood us, it just disagrees).
            throw e
        } catch {
            // Other errors (network, 404, 5xx) → fall over to the
            // secondary host. If that ALSO fails, the cachedFallback
            // path inside the helper handles the .unknown emission.
            logger.info("Gemini quota primary host \(primary.host ?? "?") failed; trying secondary \(secondary.host ?? "?")")
            let usage = try await callRetrieveUserQuota(token: token, project: project, endpoint: secondary)
            preferredQuotaHost = secondary
            return usage
        }
    }

    private func callRetrieveUserQuota(token: String, project: String, endpoint: URL) async throws -> UsageData {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Clawdmeter/1.0 (+gemini-compat)", forHTTPHeaderField: "User-Agent")

        // Body: `{"project": "<projectId>"}` per the gemini CLI source.
        // Server tolerates empty string project for personal-OAuth users
        // (verified via Antigravity which uses the same endpoint without
        // a GCP project for free-tier accounts).
        let body: [String: Any] = ["project": project]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: req)
        } catch {
            logger.warning("Gemini retrieveUserQuota network error: \(String(describing: error), privacy: .public)")
            return try cachedFallbackOrThrow(reason: "network")
        }
        guard let http = response as? HTTPURLResponse else {
            return try cachedFallbackOrThrow(reason: "non-http")
        }

        switch http.statusCode {
        case 200:
            if let usage = parseRetrieveUserQuotaResponse(data) {
                return usage
            }
            let preview = String(data: data.prefix(500), encoding: .utf8) ?? "<binary>"
            logger.warning("Gemini retrieveUserQuota parse miss; body preview: \(preview, privacy: .public)")
            return try cachedFallbackOrThrow(reason: "parse-miss")
        case 400, 403:
            // 400 INVALID_ARGUMENT typically means "missing project"; 403
            // PERMISSION_DENIED for an unfamiliar project also routes here.
            // Hint to the outer caller to discover via loadCodeAssist.
            let preview = String(data: data.prefix(300), encoding: .utf8) ?? ""
            logger.info("Gemini retrieveUserQuota \(http.statusCode) — body: \(preview, privacy: .public)")
            if preview.lowercased().contains("project") {
                throw AISourceError.dataSourceContractViolation(
                    detail: "retrieveUserQuota needs-project (status \(http.statusCode))"
                )
            }
            throw AISourceError.unauthenticated
        case 401:
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

    /// Parse retrieveUserQuota's `{buckets: [{modelId, remainingAmount,
    /// remainingFraction, resetTime}]}` response. Field names verified
    /// against gemini CLI bundle.
    private func parseRetrieveUserQuotaResponse(_ data: Data) -> UsageData? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let buckets = root["buckets"] as? [[String: Any]] else {
            return nil
        }

        // Filter to gemini-* buckets, pick the WORST (highest used%) —
        // matches Antigravity's "show me the most-constrained gauge"
        // behavior + CodexSource's `pick best bucket` pattern.
        var bestSession: (pct: Int, resetEpoch: Int)?
        for bucket in buckets {
            guard let modelId = bucket["modelId"] as? String,
                  modelId.lowercased().hasPrefix("gemini") else { continue }
            guard let fraction = bucket["remainingFraction"] as? Double else { continue }
            // used% = (1 - remaining%) * 100, per gemini CLI's logic.
            let usedPct = max(0, min(100, Int(((1.0 - fraction) * 100).rounded())))
            let resetEpoch = Self.parseResetTime(bucket["resetTime"])
            if let cur = bestSession, usedPct < cur.pct { continue }
            bestSession = (usedPct, resetEpoch)
        }

        guard let session = bestSession else {
            logger.info("Gemini retrieveUserQuota: no gemini-* buckets in response (got \(buckets.count, privacy: .public) total)")
            return nil
        }

        let now = Date()
        let nowEpoch = Int(now.timeIntervalSince1970)
        let sessionMins = max(0, (session.resetEpoch - nowEpoch + 59) / 60)

        // No "weekly" concept in cloudcode-pa's bucket response — it's
        // per-model with 5h refresh (matches Claude's session window). We
        // leave weekly at zero + 7 days out for now; future iteration can
        // surface a separate billing-cycle endpoint if Google exposes one.
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

    /// Reset-time parser. Try ISO 8601 (verified — gemini CLI surfaces it
    /// as a string), then epoch seconds / millis.
    private static func parseResetTime(_ raw: Any?) -> Int {
        if let s = raw as? String {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = iso.date(from: s) { return Int(d.timeIntervalSince1970) }
            let iso2 = ISO8601DateFormatter()
            iso2.formatOptions = [.withInternetDateTime]
            if let d = iso2.date(from: s) { return Int(d.timeIntervalSince1970) }
        }
        if let n = raw as? Int {
            return n > 10_000_000_000 ? n / 1000 : n
        }
        if let d = raw as? Double {
            return d > 10_000_000_000 ? Int(d / 1000) : Int(d)
        }
        // Fallback: 5h from now if reset time is unparseable.
        return Int(Date().timeIntervalSince1970) + 5 * 3600
    }

    // MARK: - loadCodeAssist (project discovery)

    /// Hit loadCodeAssist with metadata to discover the project. Mirrors
    /// the gemini CLI's `refreshAvailableCredits` flow.
    private func discoverProjectIdViaLoadCodeAssist(token: String) async throws -> String {
        var req = URLRequest(url: loadCodeAssistEndpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Clawdmeter/1.0 (+gemini-compat)", forHTTPHeaderField: "User-Agent")
        let body: [String: Any] = [
            "metadata": [
                "ideType": "IDE_UNSPECIFIED",
                "platform": "PLATFORM_UNSPECIFIED",
                "pluginType": "GEMINI"
            ]
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await urlSession.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AISourceError.dataSourceContractViolation(detail: "loadCodeAssist failed")
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AISourceError.dataSourceContractViolation(detail: "loadCodeAssist malformed response")
        }
        // The response carries `cloudaicompanionProject` for paid-tier
        // users; falls back to an empty string for personal-OAuth.
        if let proj = root["cloudaicompanionProject"] as? String, !proj.isEmpty {
            return proj
        }
        return ""
    }

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
        if let last = lastSession, lastUpdatedAt != nil {
            let mins = max(0, (last.resetEpoch - nowEpoch + 59) / 60)
            // `updatedAt: now` (not `lastUpdatedAt`) so UsagePoller's E3
            // shouldReplace check accepts this emission — otherwise the
            // poller drops the .unknown status update (same epoch + same
            // updatedAt → "stale, ignore") and the dashboard keeps
            // displaying the last .allowed snapshot, never firing the D7
            // orange stale badge. The badge wording reads "Stale · updated
            // N secs ago"; "N secs ago" = "last poll attempt", while
            // sessionEpoch still points at the cached reset target so the
            // countdown remains honest.
            return UsageData(
                sessionPct: last.pct,
                sessionResetMins: mins,
                sessionEpoch: last.resetEpoch,
                weeklyPct: lastWeekly?.pct ?? 0,
                weeklyResetMins: 7 * 24 * 60,
                weeklyEpoch: lastWeekly?.resetEpoch ?? nowEpoch + 7 * 24 * 3600,
                status: .unknown,
                representativeClaim: .unknown,
                updatedAt: now
            )
        }
        logger.info("Gemini fallback no-cache: reason=\(reason, privacy: .public); surfacing as dataSourceContractViolation so UI shows Connecting…")
        throw AISourceError.dataSourceContractViolation(
            detail: "Gemini first-poll \(reason) — no cached usage yet, UI stays at Connecting…"
        )
    }
}
#endif

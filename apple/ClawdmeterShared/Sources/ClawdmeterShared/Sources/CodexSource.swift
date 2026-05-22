#if os(macOS)
import Foundation
import OSLog

/// ChatGPT/Codex usage source.
///
/// Codex's per-account rate-limit state is reported in TWO places:
///
/// 1. **Local JSONL rollouts** (`~/.codex/sessions/.../rollout-*.jsonl`) carry
///    a `rate_limits` payload inside each `event_msg.token_count` event.
///    These reflect the **per-CLI-bucket** quota (`limit_id: "codex"`) and
///    are written every time Codex CLI hits the model API.
///
/// 2. **Live HTTP endpoint** `chatgpt.com/backend-api/wham/usage` returns
///    the **account-wide multi-bucket** view. This is what Codex Desktop's
///    "Usage remaining" menu shows. The bucket counts can diverge sharply
///    from the JSONL one: the CLI bucket might read 19% while the account
///    bucket reads 78% because ChatGPT chat usage counts against the
///    account-wide window but not the CLI-specific one.
///
/// We try the live endpoint first because that matches what Codex Desktop
/// shows, and fall back to JSONL parsing when the network call fails
/// (offline, expired token, endpoint change, etc.) — JSONL is local and
/// always works, just less complete.
///
/// Per-bucket fields:
///   - `primary`   = 5-hour rolling session window (used_percent, resets_at)
///   - `secondary` = 7-day weekly window (used_percent, resets_at)
///   - `rate_limit_reached_type` = nil when allowed, string when limited
///   - `plan_type` (e.g. "prolite", "plus") — informational
public final class CodexSource: AISource {

    public let providerID = "codex"
    public let displayName = "Codex"

    private let tokenProvider: TokenProvider
    private let urlSession: URLSession
    private let logger = Logger(subsystem: "com.clawdmeter.shared", category: "CodexSource")

    /// Candidate live-usage endpoints, tried in order. Codex's binary
    /// references both `/wham/usage` and `/api/codex/usage`; we try the
    /// newer one first and fall back if it 404s. The fallback chain is
    /// also our defense if OpenAI renames the path.
    private static let liveUsageEndpoints: [String] = [
        "https://chatgpt.com/backend-api/wham/usage",
        "https://chatgpt.com/backend-api/api/codex/usage",
    ]

    public init(tokenProvider: TokenProvider, urlSession: URLSession? = nil) {
        self.tokenProvider = tokenProvider
        if let urlSession {
            self.urlSession = urlSession
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 8     // bounded — falls back fast
            config.timeoutIntervalForResource = 12
            config.waitsForConnectivity = false      // don't queue while offline
            self.urlSession = URLSession(configuration: config)
        }
    }

    public var isAuthenticated: Bool { tokenProvider.hasToken }

    @discardableResult
    public func refreshCredentialsIfNeeded() async throws -> Bool {
        try await tokenProvider.refreshIfNeeded()
    }

    public func poll() async throws -> UsageData {
        // Presence-check the CLI auth as a proxy for "Codex is configured".
        guard tokenProvider.hasToken else {
            throw AISourceError.unauthenticated
        }

        // Path 1 — try the live HTTP endpoint that Codex Desktop uses.
        // This is the only way to get the account-wide bucket (which can
        // be substantially higher than the CLI-only bucket exposed in
        // the JSONLs). Any failure path falls through to the local JSONL.
        if let live = await fetchLiveUsage() {
            logger.info("Codex live usage: session=\(live.sessionPct)% (resets \(live.sessionEpoch)) weekly=\(live.weeklyPct)% source=wham")
            return live
        }

        // Path 2 — fall back to the local JSONL rate_limits payload. This
        // is the CLI-specific bucket — accurate but potentially lower
        // than what the user sees in Codex Desktop.
        guard let url = mostRecentSessionFile() else {
            logger.warning("No Codex session JSONL found under ~/.codex/sessions")
            throw AISourceError.dataSourceContractViolation(
                detail: "No Codex sessions at ~/.codex/sessions — run `codex` once to seed."
            )
        }

        do {
            let usage = try parseLatestUsage(from: url)
            logger.info("Codex usage (JSONL fallback): session=\(usage.sessionPct)% (resets \(usage.sessionEpoch)) weekly=\(usage.weeklyPct)% source=jsonl")
            return usage
        } catch let err as AISourceError {
            throw err
        } catch {
            logger.error("Codex JSONL parse failed: \(String(describing: error))")
            throw AISourceError.malformedResponse(detail: "Codex JSONL parse: \(error)")
        }
    }

    // MARK: - Live HTTP usage poll

    /// Hit Codex's account-wide usage endpoint and return the parsed
    /// snapshot. Returns nil for any failure path (no token, no account
    /// id, network error, non-2xx response, decode failure) — the caller
    /// then falls back to JSONL.
    ///
    /// We try each candidate endpoint in order so we survive OpenAI
    /// renaming the path (the `/wham/usage` → `/api/codex/usage` switch
    /// happened mid-2026 in some clients).
    private func fetchLiveUsage() async -> UsageData? {
        guard let accessToken = tokenProvider.currentAccessToken else {
            return nil
        }
        let accountId = (tokenProvider as? CodexTokenProvider)?.currentAccountId

        for endpoint in Self.liveUsageEndpoints {
            guard let url = URL(string: endpoint) else { continue }
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            if let accountId {
                req.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-ID")
            }
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            // Codex CLI's user agent — some endpoints require a client
            // identifier or they 403. Mirror what the CLI sends.
            req.setValue("Clawdmeter/1.0 (+Codex-compat)", forHTTPHeaderField: "User-Agent")

            do {
                let (data, response) = try await urlSession.data(for: req)
                guard let http = response as? HTTPURLResponse else { continue }
                guard (200..<300).contains(http.statusCode) else {
                    if http.statusCode == 401 || http.statusCode == 403 {
                        // Token rejected — no point trying the next endpoint
                        // with the same credentials. Surface as auth error
                        // so the caller can prompt for re-login if needed,
                        // but for the live-path we silently fall through to
                        // the JSONL parser.
                        logger.warning("Codex \(endpoint, privacy: .public) returned \(http.statusCode) — falling back to JSONL")
                        return nil
                    }
                    logger.info("Codex \(endpoint, privacy: .public) returned \(http.statusCode) — trying next")
                    continue
                }
                if let parsed = parseLiveUsagePayload(data) {
                    return parsed
                }
                // Non-fatal decode failure; try the next endpoint.
                logger.info("Codex \(endpoint, privacy: .public) decoded to no usable buckets — trying next")
            } catch {
                logger.info("Codex \(endpoint, privacy: .public) network error: \(String(describing: error)) — trying next")
                continue
            }
        }
        return nil
    }

    /// Parse the live `/wham/usage` payload into UsageData. The endpoint
    /// returns BOTH a legacy single-bucket `rate_limits` AND a richer
    /// `rate_limits_by_limit_id` map (per the Codex CLI's binary type
    /// `GetAccountRateLimitsResponse`).
    ///
    /// v0.22.10 rewrite: previously we picked the bucket with the
    /// highest `primary.used_percent` and inherited its `secondary` as
    /// the weekly. That's wrong when buckets are independent — Codex
    /// returns one bucket per `limit_id` (e.g. `codex`, `codex-pro`,
    /// `codex-fast`), each with its own (primary, secondary) pair.
    /// Pairing the worst primary with that bucket's secondary
    /// dropped the actual user-facing 5h reading whenever the
    /// constrained tier wasn't the same bucket whose weekly the user
    /// was watching.
    ///
    /// Now we walk every bucket and track the highest used_percent
    /// **per window-minutes class** independently. A 300-minute bucket
    /// from any limit_id can become the session; a 10080-minute bucket
    /// from any limit_id can become the weekly. This matches Codex
    /// Desktop's behavior of showing the worst-case 5h + worst-case
    /// weekly side-by-side regardless of bucket grouping.
    private func parseLiveUsagePayload(_ data: Data) -> UsageData? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        // Collect candidate bucket payloads. Some responses nest under
        // top-level `rateLimitsByLimitId` (camelCase per ts), others
        // under `rate_limits_by_limit_id` (snake_case per rust).
        var buckets: [[String: Any]] = []
        for key in ["rateLimitsByLimitId", "rate_limits_by_limit_id"] {
            if let map = root[key] as? [String: [String: Any]] {
                buckets.append(contentsOf: map.values)
            } else if let map = root[key] as? [String: Any] {
                // Some servers return it as [String: Any] when only one bucket
                // is present.
                for (_, v) in map { if let v = v as? [String: Any] { buckets.append(v) } }
            }
        }
        // Single-bucket legacy field.
        for key in ["rateLimits", "rate_limits"] {
            if let single = root[key] as? [String: Any] {
                buckets.append(single)
            }
        }

        // Walk every (primary, secondary) pair across every bucket and
        // pick window-by-window winners. 5h class ≈ 300 minutes;
        // weekly class ≈ 10080 minutes. We don't hard-equality on
        // window_minutes — accept anything ≤ 600 as a session bucket,
        // anything ≥ 1440 as a weekly bucket. That stays robust if
        // Codex starts returning a daily (1440) bucket later.
        var sessionWinner: BucketView?
        var weeklyWinner: BucketView?
        var reachedAny: String?
        for raw in buckets {
            if let reached = raw["rate_limit_reached_type"] as? String, !reached.isEmpty {
                reachedAny = reached
            }
            if let primary = BucketView(rawBucket: raw["primary"]) {
                if Self.isSessionWindow(primary.windowMinutes) {
                    if sessionWinner == nil || primary.usedPercent > sessionWinner!.usedPercent {
                        sessionWinner = primary
                    }
                } else if Self.isWeeklyWindow(primary.windowMinutes) {
                    if weeklyWinner == nil || primary.usedPercent > weeklyWinner!.usedPercent {
                        weeklyWinner = primary
                    }
                }
            }
            if let secondary = BucketView(rawBucket: raw["secondary"]) {
                if Self.isSessionWindow(secondary.windowMinutes) {
                    if sessionWinner == nil || secondary.usedPercent > sessionWinner!.usedPercent {
                        sessionWinner = secondary
                    }
                } else if Self.isWeeklyWindow(secondary.windowMinutes) {
                    if weeklyWinner == nil || secondary.usedPercent > weeklyWinner!.usedPercent {
                        weeklyWinner = secondary
                    }
                }
            }
        }

        // If no session bucket was identifiable but at least one bucket
        // had a primary, fall back to the highest-primary across all
        // (preserves prior behavior for endpoints that don't expose
        // `window_minutes` — e.g. mocked test fixtures).
        if sessionWinner == nil {
            for raw in buckets {
                if let primary = BucketView(rawBucket: raw["primary"]) {
                    if sessionWinner == nil || primary.usedPercent > sessionWinner!.usedPercent {
                        sessionWinner = primary
                    }
                }
            }
        }
        guard let session = sessionWinner else { return nil }

        let now = Date()
        let nowEpoch = Int(now.timeIntervalSince1970)
        let sessionMins = max(0, (session.resetsAt - nowEpoch + 59) / 60)

        let weeklyPct: Int
        let weeklyEpoch: Int
        let weeklyMins: Int
        if let weekly = weeklyWinner {
            weeklyPct = Int(weekly.usedPercent.rounded())
            weeklyEpoch = weekly.resetsAt
            weeklyMins = max(0, (weekly.resetsAt - nowEpoch + 59) / 60)
        } else {
            weeklyPct = 0
            weeklyEpoch = nowEpoch + 7 * 24 * 3600
            weeklyMins = 7 * 24 * 60
        }

        let resetIsPast = session.resetsAt <= nowEpoch
        let status: UsageData.Status
        if reachedAny != nil {
            status = .limited
        } else if resetIsPast {
            status = .notStarted
        } else {
            status = .allowed
        }

        let weeklyWindowM = weeklyWinner?.windowMinutes ?? 0
        let weeklyPresent = weeklyWinner != nil
        logger.info("Codex parsed: session=\(Int(session.usedPercent.rounded()))% (window=\(session.windowMinutes ?? 0)m) weekly=\(weeklyPct)% (window=\(weeklyWindowM)m, present=\(weeklyPresent))")
        return UsageData(
            sessionPct: Int(session.usedPercent.rounded()),
            sessionResetMins: sessionMins,
            sessionEpoch: session.resetsAt,
            weeklyPct: weeklyPct,
            weeklyResetMins: weeklyMins,
            weeklyEpoch: weeklyEpoch,
            status: status,
            representativeClaim: .fiveHour,
            updatedAt: now
        )
    }

    /// 300 minutes = 5h session; some test fixtures use 60 or 240, so
    /// accept anything ≤ 600 as session-class (10h cap).
    private static func isSessionWindow(_ windowMinutes: Int?) -> Bool {
        guard let m = windowMinutes else { return false }
        return m > 0 && m <= 600
    }

    /// 1440 = daily (counted as "weekly-class" for the gauge); 10080 = weekly.
    private static func isWeeklyWindow(_ windowMinutes: Int?) -> Bool {
        guard let m = windowMinutes else { return false }
        return m >= 1440
    }


    /// Tolerant decoder for a `{used_percent, window_minutes?, resets_at}`
    /// bucket — handles both camelCase (`usedPercent`/`resetsAt`) and
    /// snake_case (`used_percent`/`resets_at`) keys.
    private struct BucketView {
        let usedPercent: Double
        let resetsAt: Int
        /// v0.22.10: surfaces `window_minutes` so the parser can match
        /// buckets to the 5h-class vs weekly-class regardless of which
        /// limit_id Codex grouped them under.
        let windowMinutes: Int?

        init?(rawBucket: Any?) {
            guard let dict = rawBucket as? [String: Any] else { return nil }
            let pct = (dict["used_percent"] as? Double)
                ?? (dict["usedPercent"] as? Double)
                ?? Double(dict["used_percent"] as? Int ?? 0)
            let resets = (dict["resets_at"] as? Int)
                ?? (dict["resetsAt"] as? Int)
                ?? Int(dict["resets_at"] as? Double ?? 0)
            guard resets > 0 else { return nil }
            self.usedPercent = pct
            self.resetsAt = resets
            self.windowMinutes = (dict["window_minutes"] as? Int)
                ?? (dict["windowMinutes"] as? Int)
        }
    }

    // MARK: - JSONL discovery

    /// Walk `~/.codex/sessions` recursively and return the most recently-modified
    /// `.jsonl` file. Codex writes one rollout per CLI invocation; the most
    /// recent file's tail has the freshest `rate_limits` block.
    private func mostRecentSessionFile() -> URL? {
        let fm = FileManager.default
        let sessionsRoot = fm.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
        guard fm.fileExists(atPath: sessionsRoot.path) else { return nil }

        guard let enumerator = fm.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var newest: (url: URL, mtime: Date)?
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let mtime = values.contentModificationDate
            else { continue }
            if newest == nil || mtime > newest!.mtime {
                newest = (url, mtime)
            }
        }
        return newest?.url
    }

    // MARK: - JSONL parse

    private struct RateLimitsPayload: Decodable {
        struct Bucket: Decodable {
            let used_percent: Double
            let window_minutes: Int?
            let resets_at: Int
        }
        let primary: Bucket
        let secondary: Bucket?
        let rate_limit_reached_type: String?
        let plan_type: String?
    }

    /// Scan the JSONL forward, keeping the most recent line that contains a
    /// `rate_limits` payload. Memory-mapped — even multi-MB session files are
    /// effectively free to scan.
    private func parseLatestUsage(from url: URL) throws -> UsageData {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        let needle = Data("\"rate_limits\"".utf8)
        let newline: UInt8 = 0x0A

        var latestLine: Data?
        var cursor = data.startIndex
        while cursor < data.endIndex {
            let lineEnd: Data.Index
            if let nl = data[cursor...].firstIndex(of: newline) {
                lineEnd = nl
            } else {
                lineEnd = data.endIndex
            }
            let line = data[cursor..<lineEnd]
            if line.range(of: needle) != nil {
                latestLine = line
            }
            cursor = lineEnd < data.endIndex ? data.index(after: lineEnd) : data.endIndex
        }

        guard let line = latestLine else {
            throw AISourceError.dataSourceContractViolation(
                detail: "Session file has no rate_limits entries yet: \(url.lastPathComponent)"
            )
        }

        // Outer envelope: {"timestamp": "...", "type": "event_msg",
        //                  "payload": {"type": "token_count",
        //                              "info": {...token counts...},
        //                              "rate_limits": {...}}}
        // (rate_limits is a SIBLING of info, not nested inside it — confirmed
        // by inspection of the rollout JSONL.)
        guard let obj = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            throw AISourceError.malformedResponse(detail: "Codex JSONL line is not a JSON object")
        }
        guard let payload = obj["payload"] as? [String: Any],
              let rateLimits = payload["rate_limits"] as? [String: Any]
        else {
            throw AISourceError.malformedResponse(detail: "Codex JSONL: no payload.rate_limits")
        }

        let rlData = try JSONSerialization.data(withJSONObject: rateLimits, options: [])
        let rl = try JSONDecoder().decode(RateLimitsPayload.self, from: rlData)

        let now = Date()
        let nowEpoch = Int(now.timeIntervalSince1970)

        // Primary = 5-hour session window. `resets_at` is server-time epoch
        // seconds; clamp negative deltas to zero (a tick past reset before the
        // next CLI invocation refreshes the file).
        let sessionPct = Int(rl.primary.used_percent.rounded())
        let sessionEpoch = rl.primary.resets_at
        let sessionMins = max(0, (sessionEpoch - nowEpoch + 59) / 60)

        // Secondary = 7-day weekly window. Optional in the schema; fall back to
        // a placeholder if absent so the UI still renders.
        let weeklyPct: Int
        let weeklyEpoch: Int
        let weeklyMins: Int
        if let sec = rl.secondary {
            weeklyPct = Int(sec.used_percent.rounded())
            weeklyEpoch = sec.resets_at
            weeklyMins = max(0, (sec.resets_at - nowEpoch + 59) / 60)
        } else {
            weeklyPct = 0
            weeklyEpoch = nowEpoch + 7 * 24 * 3600
            weeklyMins = 7 * 24 * 60
        }

        // Decide whether the recorded 5h window is still genuinely active.
        // The only authoritative signal Codex CLI gives us is `resets_at`:
        // if it's in the past, the window has reset since the file was
        // written and the recorded percentage is stale. Anything else —
        // including long idle gaps — is still "the same active window the
        // server is counting against", same as Claude's behavior.
        let resetIsPast = sessionEpoch <= nowEpoch
        let inactive = resetIsPast

        let status: UsageData.Status
        if rl.rate_limit_reached_type != nil {
            status = .limited
        } else if inactive {
            status = .notStarted
        } else {
            status = .allowed
        }

        return UsageData(
            sessionPct: sessionPct,
            sessionResetMins: sessionMins,
            sessionEpoch: sessionEpoch,
            weeklyPct: weeklyPct,
            weeklyResetMins: weeklyMins,
            weeklyEpoch: weeklyEpoch,
            status: status,
            representativeClaim: .fiveHour,
            updatedAt: now
        )
    }
}
#endif // os(macOS)

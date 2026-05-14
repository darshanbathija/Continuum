#if os(macOS)
import Foundation
import OSLog

/// ChatGPT/Codex usage source.
///
/// Codex CLI writes its `rate_limits` server response into every session's
/// JSONL rollout file (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`) inside
/// `token_count` `event_msg` payloads. The newest entry across all sessions
/// is the authoritative current state — it carries:
///   - `primary`   = 5-hour rolling session window (used_percent, resets_at)
///   - `secondary` = 7-day weekly window (used_percent, resets_at)
///   - `rate_limit_reached_type` = nil when allowed, string when limited
///   - `plan_type` (e.g. "prolite", "plus") — informational
///
/// This avoids the network entirely: Codex CLI's auth is a ChatGPT JWT that
/// works against `chatgpt.com/backend-api/*` but not `api.openai.com`, and the
/// rate-limit endpoint isn't part of any public contract. The CLI's local
/// rollout files are the canonical source of truth on this machine.
public final class CodexSource: AISource {

    public let providerID = "codex"
    public let displayName = "Codex"

    private let tokenProvider: TokenProvider
    private let logger = Logger(subsystem: "com.clawdmeter.shared", category: "CodexSource")

    public init(tokenProvider: TokenProvider, urlSession: URLSession? = nil) {
        self.tokenProvider = tokenProvider
        // urlSession ignored — we read local files only. Keeping the parameter
        // preserves the AISource initializer shape used by AppRuntime / tests.
        _ = urlSession
    }

    public var isAuthenticated: Bool { tokenProvider.hasToken }

    @discardableResult
    public func refreshCredentialsIfNeeded() async throws -> Bool {
        try await tokenProvider.refreshIfNeeded()
    }

    public func poll() async throws -> UsageData {
        // Presence-check the CLI auth as a proxy for "Codex is configured".
        // We don't actually hit the network; this just gates the gauge.
        guard tokenProvider.hasToken else {
            throw AISourceError.unauthenticated
        }

        guard let url = mostRecentSessionFile() else {
            logger.warning("No Codex session JSONL found under ~/.codex/sessions")
            throw AISourceError.dataSourceContractViolation(
                detail: "No Codex sessions at ~/.codex/sessions — run `codex` once to seed."
            )
        }

        do {
            let usage = try parseLatestUsage(from: url)
            logger.info("Codex usage: session=\(usage.sessionPct)% (resets \(usage.sessionEpoch)) weekly=\(usage.weeklyPct)% (resets \(usage.weeklyEpoch))")
            return usage
        } catch let err as AISourceError {
            throw err
        } catch {
            logger.error("Codex JSONL parse failed: \(String(describing: error))")
            throw AISourceError.malformedResponse(detail: "Codex JSONL parse: \(error)")
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

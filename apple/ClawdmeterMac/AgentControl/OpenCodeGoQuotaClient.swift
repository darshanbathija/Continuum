import Foundation
import ClawdmeterShared

/// Fetches OpenCode Go plan quota (5h rolling, weekly, monthly).
public struct OpenCodeGoQuotaClient: Sendable {
    public struct Window: Equatable, Sendable {
        public let usagePercent: Int
        public let resetInSec: Int

        public init(usagePercent: Int, resetInSec: Int) {
            self.usagePercent = usagePercent
            self.resetInSec = resetInSec
        }
    }

    public struct Snapshot: Equatable, Sendable {
        public let rolling: Window?
        public let weekly: Window?
        public let monthly: Window?
        public let updatedAt: Date

        public init(rolling: Window?, weekly: Window?, monthly: Window?, updatedAt: Date) {
            self.rolling = rolling
            self.weekly = weekly
            self.monthly = monthly
            self.updatedAt = updatedAt
        }
    }

    public enum Error: Swift.Error, Equatable {
        case missingCredentials
        case malformedResponse(String)
        case transport(String)
    }

    public init() {}

    private static let usageEndpoint = URL(string: "https://opencode.ai/zen/go/v1/usage")!
    private static let dashboardPrefix = "https://opencode.ai/workspace/"
    private static let dashboardSuffix = "/go"
    private static let userAgent = "Continuum/1.0 (OpenCode Go quota probe)"

    func fetch(apiKey: String?, dashboard: (workspaceId: String, authCookie: String)?) async throws -> Snapshot {
        if let apiKey, !apiKey.isEmpty {
            if let snapshot = try? await fetchUsageAPI(apiKey: apiKey) {
                return snapshot
            }
        }
        guard let dashboard else {
            throw Error.missingCredentials
        }
        return try await fetchDashboard(workspaceId: dashboard.workspaceId, authCookie: dashboard.authCookie)
    }

    // MARK: - Usage API (proposed upstream shape)

    private func fetchUsageAPI(apiKey: String) async throws -> Snapshot {
        var request = URLRequest(url: Self.usageEndpoint)
        request.timeoutInterval = 8
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Error.transport("missing HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Error.malformedResponse("usage API HTTP \(http.statusCode)")
        }
        return try Self.parseUsageAPI(data)
    }

    internal static func parseUsageAPI(_ data: Data) throws -> Snapshot {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dict = object as? [String: Any] else {
            throw Error.malformedResponse("usage API not an object")
        }
        let rolling = parseAPIWindow(dict["rolling5h"] as? [String: Any])
            ?? parseAPIWindow(dict["rolling"] as? [String: Any])
        let weekly = parseAPIWindow(dict["weekly"] as? [String: Any])
        let monthly = parseAPIWindow(dict["monthly"] as? [String: Any])
        guard rolling != nil || weekly != nil || monthly != nil else {
            throw Error.malformedResponse("usage API missing windows")
        }
        return Snapshot(
            rolling: rolling,
            weekly: weekly,
            monthly: monthly,
            updatedAt: Date()
        )
    }

    private static func parseAPIWindow(_ dict: [String: Any]?) -> Window? {
        guard let dict else { return nil }
        let pct = intValue(dict["usagePercent"]) ?? intValue(dict["usage_percent"])
        let reset = intValue(dict["resetInSec"]) ?? intValue(dict["resets_in_seconds"])
        guard let pct, let reset else { return nil }
        return Window(usagePercent: min(100, max(0, pct)), resetInSec: max(0, reset))
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let n as Int: return n
        case let n as Double: return Int(n.rounded())
        case let s as String: return Int(s)
        default: return nil
        }
    }

    // MARK: - Dashboard scrape

    private func fetchDashboard(workspaceId: String, authCookie: String) async throws -> Snapshot {
        let encoded = workspaceId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? workspaceId
        guard let url = URL(string: Self.dashboardPrefix + encoded + Self.dashboardSuffix) else {
            throw Error.malformedResponse("invalid workspace id")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        request.setValue("auth=\(authCookie)", forHTTPHeaderField: "Cookie")
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Error.transport("missing HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Error.malformedResponse("dashboard HTTP \(http.statusCode)")
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw Error.malformedResponse("dashboard not UTF-8")
        }
        return try Self.parseDashboardHTML(html)
    }

    internal static func parseDashboardHTML(_ html: String) throws -> Snapshot {
        let rolling = parseWindow(html, pctFirst: rollingPctFirst, resetFirst: rollingResetFirst)
        let weekly = parseWindow(html, pctFirst: weeklyPctFirst, resetFirst: weeklyResetFirst)
        let monthly = parseWindow(html, pctFirst: monthlyPctFirst, resetFirst: monthlyResetFirst)
        guard rolling != nil || weekly != nil || monthly != nil else {
            throw Error.malformedResponse("dashboard missing usage windows")
        }
        return Snapshot(
            rolling: rolling,
            weekly: weekly,
            monthly: monthly,
            updatedAt: Date()
        )
    }

    private static let numberPattern = #"(-?\d+(?:\.\d+)?)"#

    private static let rollingPctFirst = try! NSRegularExpression(
        pattern: #"rollingUsage:\$R\[\d+\]=\{[^}]*usagePercent:"# + numberPattern + #"[^}]*resetInSec:"# + numberPattern + #"[^}]*\}"#)
    private static let rollingResetFirst = try! NSRegularExpression(
        pattern: #"rollingUsage:\$R\[\d+\]=\{[^}]*resetInSec:"# + numberPattern + #"[^}]*usagePercent:"# + numberPattern + #"[^}]*\}"#)
    private static let weeklyPctFirst = try! NSRegularExpression(
        pattern: #"weeklyUsage:\$R\[\d+\]=\{[^}]*usagePercent:"# + numberPattern + #"[^}]*resetInSec:"# + numberPattern + #"[^}]*\}"#)
    private static let weeklyResetFirst = try! NSRegularExpression(
        pattern: #"weeklyUsage:\$R\[\d+\]=\{[^}]*resetInSec:"# + numberPattern + #"[^}]*usagePercent:"# + numberPattern + #"[^}]*\}"#)
    private static let monthlyPctFirst = try! NSRegularExpression(
        pattern: #"monthlyUsage:\$R\[\d+\]=\{[^}]*usagePercent:"# + numberPattern + #"[^}]*resetInSec:"# + numberPattern + #"[^}]*\}"#)
    private static let monthlyResetFirst = try! NSRegularExpression(
        pattern: #"monthlyUsage:\$R\[\d+\]=\{[^}]*resetInSec:"# + numberPattern + #"[^}]*usagePercent:"# + numberPattern + #"[^}]*\}"#)

    /// Upper bound for a plausible reset window (≈ 13 months). Larger values are
    /// almost certainly a regex match against unrelated HTML, so we drop them to
    /// 0 ("unknown") rather than render "resets in 5000 days".
    private static let maxResetInSec = 400 * 24 * 3600

    private static func parseWindow(
        _ html: String,
        pctFirst: NSRegularExpression,
        resetFirst: NSRegularExpression
    ) -> Window? {
        let ns = html as NSString
        let range = NSRange(location: 0, length: ns.length)
        if let match = pctFirst.firstMatch(in: html, range: range), match.numberOfRanges >= 3 {
            let pct = Int(ns.substring(with: match.range(at: 1)).split(separator: ".").first ?? "0") ?? 0
            let reset = Int(ns.substring(with: match.range(at: 2)).split(separator: ".").first ?? "0") ?? 0
            return makeWindow(pct: pct, reset: reset)
        }
        if let match = resetFirst.firstMatch(in: html, range: range), match.numberOfRanges >= 3 {
            let reset = Int(ns.substring(with: match.range(at: 1)).split(separator: ".").first ?? "0") ?? 0
            let pct = Int(ns.substring(with: match.range(at: 2)).split(separator: ".").first ?? "0") ?? 0
            return makeWindow(pct: pct, reset: reset)
        }
        return nil
    }

    private static func makeWindow(pct: Int, reset: Int) -> Window {
        let boundedReset = (reset >= 0 && reset <= maxResetInSec) ? reset : 0
        return Window(usagePercent: min(100, max(0, pct)), resetInSec: boundedReset)
    }
}

extension OpenCodeGoQuotaClient.Snapshot {
    func asUsageData(now: Date = Date()) -> UsageData {
        // Do NOT coalesce missing windows onto a sibling's value — that
        // rendered an unfetched weekly/monthly meter as a real percentage.
        // Absent windows fall to 0 / nil and the UI hides them instead.
        let rollingPct = rolling?.usagePercent ?? 0
        let weeklyPct = weekly?.usagePercent ?? 0
        let rollingReset = windowEpoch(now: now, resetInSec: rolling?.resetInSec)
        let weeklyReset = windowEpoch(now: now, resetInSec: weekly?.resetInSec)
        let monthlyReset = windowEpoch(now: now, resetInSec: monthly?.resetInSec)
        // Limited only when a window we ACTUALLY fetched is maxed — a fabricated
        // value must never flip the gauge to "limited".
        let fetchedPcts = [rolling?.usagePercent, weekly?.usagePercent, monthly?.usagePercent]
            .compactMap { $0 }
        let status: UsageData.Status = fetchedPcts.contains(where: { $0 >= 100 })
            ? .limited
            : .allowed
        return UsageData(
            sessionPct: rollingPct,
            sessionResetMins: minutesUntilReset(now: now, resetEpoch: rollingReset),
            sessionEpoch: rollingReset,
            weeklyPct: weeklyPct,
            weeklyResetMins: minutesUntilReset(now: now, resetEpoch: weeklyReset),
            weeklyEpoch: weeklyReset,
            status: status,
            representativeClaim: .fiveHour,
            updatedAt: updatedAt,
            opencodeGoQuota: UsageData.OpenCodeGoQuota(
                weeklyAvailable: weekly != nil,
                monthlyPct: monthly?.usagePercent,
                monthlyResetMins: minutesUntilReset(now: now, resetEpoch: monthlyReset),
                monthlyResetEpoch: monthlyReset
            )
        )
    }

    private func windowEpoch(now: Date, resetInSec: Int?) -> Int {
        guard let resetInSec, resetInSec > 0 else { return 0 }
        return Int(now.timeIntervalSince1970) + resetInSec
    }

    private func minutesUntilReset(now: Date, resetEpoch: Int) -> Int {
        guard resetEpoch > 0 else { return 0 }
        let delta = resetEpoch - Int(now.timeIntervalSince1970)
        return max(0, (delta + 59) / 60)
    }
}

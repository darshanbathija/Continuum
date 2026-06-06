#if os(macOS)
import Foundation
#if canImport(OSLog)
import OSLog
#endif

/// Live usage source for Cursor's CLI/IDE account.
///
/// Calls `https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage`
/// with a JWT bearer (read from the macOS Keychain by `CursorTokenProvider`)
/// and maps the response into a `UsageData` the rest of the Mac app already
/// knows how to render.
///
/// Cursor has exposed the same route in two wire shapes:
///   - Connect JSON (`Content-Type: application/json`) with `planUsage`
///     fields that match the web dashboard's Total / Auto / API rows.
///   - gRPC-Web proto, which older Cursor builds used for a coarser included
///     usage summary. We keep this as a fallback only.
///
/// **Schema is reverse-engineered**. No `.proto` file is published. The
/// capture rig is `CursorAPIClientIntegrationTests` (skipped by default,
/// runs with `CLAWDMETER_PROBE_CURSOR=1`). The fixture
/// `Fixtures/cursor-GetCurrentPeriodUsage.bin` pins the response shape so
/// CI catches a Cursor backend schema drift.
///
/// **TOS posture**: same risk class as `CodexSource` against
/// `chatgpt.com/backend-api/wham/usage` and `AntigravityLSQuotaProbe`
/// against the local language_server — internal endpoint, authenticated
/// with the user's own credentials, no destructive calls.
public final class CursorSource: AISource, @unchecked Sendable {

    public let providerID = "cursor"
    public let displayName = "Cursor"

    private let tokenProvider: TokenProvider
    private let urlSession: URLSession
    private let logger = Logger(subsystem: "com.clawdmeter.shared", category: "CursorSource")

    /// Default Cursor backend. Overridable for tests.
    public static let defaultEndpoint = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!
    private let endpoint: URL

    public init(tokenProvider: TokenProvider, urlSession: URLSession? = nil, endpoint: URL = CursorSource.defaultEndpoint) {
        self.tokenProvider = tokenProvider
        self.endpoint = endpoint
        if let urlSession {
            self.urlSession = urlSession
        } else {
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 8
            cfg.timeoutIntervalForResource = 12
            cfg.waitsForConnectivity = false
            self.urlSession = URLSession(configuration: cfg)
        }
    }

    public var isAuthenticated: Bool { tokenProvider.hasToken }

    public func refreshCredentialsIfNeeded() async throws -> Bool {
        try await tokenProvider.refreshIfNeeded()
    }

    public func poll() async throws -> UsageData {
        guard let token = tokenProvider.currentAccessToken else {
            throw AISourceError.unauthenticated
        }

        if let usage = try await pollConnectJSON(token: token) {
            return usage
        }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/grpc-web+proto", forHTTPHeaderField: "Content-Type")
        // Properly-framed empty gRPC-Web request: 1B flags + 4B BE length + 0B body.
        req.httpBody = Data([0x00, 0x00, 0x00, 0x00, 0x00])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: req)
        } catch {
            logger.warning("Cursor poll network error: \(String(describing: error), privacy: .public)")
            throw AISourceError.networkFailure(underlying: error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw AISourceError.malformedResponse(detail: "Cursor response not HTTP")
        }
        // gRPC-Web returns 200 even for grpc-status errors; check the trailer.
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw AISourceError.unauthenticated
            }
            throw AISourceError.networkFailure(
                underlying: NSError(domain: "CursorSource", code: http.statusCode,
                                    userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
            )
        }

        return try Self.parseGetCurrentPeriodUsage(grpcWebBody: data, now: Date())
    }

    private func pollConnectJSON(token: String) async throws -> UsageData? {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = Data("{}".utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: req)
        } catch {
            logger.warning("Cursor Connect JSON poll network error: \(String(describing: error), privacy: .public)")
            return nil
        }

        guard let http = response as? HTTPURLResponse else {
            return nil
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw AISourceError.unauthenticated
            }
            logger.warning("Cursor Connect JSON poll returned HTTP \(http.statusCode, privacy: .public); falling back to gRPC-Web")
            return nil
        }

        do {
            return try Self.parseGetCurrentPeriodUsage(connectJSONBody: data, now: Date())
        } catch {
            logger.warning("Cursor Connect JSON parse failed: \(String(describing: error), privacy: .public); falling back to gRPC-Web")
            return nil
        }
    }

    // MARK: - Parser

    /// Decode the Connect JSON form of Cursor's dashboard response. This is
    /// the preferred path because `planUsage` matches the web dashboard's
    /// monthly Total / Auto / API breakdown and billing-cycle reset.
    static func parseGetCurrentPeriodUsage(connectJSONBody data: Data, now: Date) throws -> UsageData {
        let decoded = try JSONDecoder().decode(CursorConnectUsageResponse.self, from: data)
        guard let plan = decoded.planUsage else {
            throw AISourceError.dataSourceContractViolation(detail: "Cursor Connect JSON missing planUsage")
        }

        let summaries = [
            decoded.autoModelSelectedDisplayMessage,
            decoded.namedModelSelectedDisplayMessage,
            plan.totalDisplayMessage,
            plan.autoDisplayMessage,
            plan.apiDisplayMessage
        ].compactMap { $0 }

        let totalPercent = Self.percentInt(plan.totalPercentUsed)
            ?? Self.parseLabeledPercent(labels: ["Total", "Total usage"], from: summaries)
            ?? Self.parsePercent(from: decoded.autoModelSelectedDisplayMessage ?? "")
            ?? 0
        let autoPercent = Self.percentInt(plan.autoPercentUsed)
            ?? Self.parseLabeledPercent(labels: ["Auto", "Auto + Composer", "Composer"], from: summaries)
        let apiPercent = Self.percentInt(plan.apiPercentUsed)
            ?? Self.parseLabeledPercent(labels: ["API"], from: summaries)
            ?? Self.parsePercent(from: decoded.namedModelSelectedDisplayMessage ?? "")

        let periodEndMs = decoded.billingCycleEnd.flatMap(Self.parseMillis)
        let periodEndEpoch = Int((periodEndMs ?? 0) / 1000)
        let nowEpoch = Int(now.timeIntervalSince1970)
        let resetMins = periodEndEpoch > 0 ? max(0, (periodEndEpoch - nowEpoch + 59) / 60) : 0
        let status: UsageData.Status = periodEndEpoch > 0 && periodEndEpoch <= nowEpoch ? .notStarted : .allowed

        let includedLabel = Self.includedSpendLabel(includedSpend: plan.includedSpend, limit: plan.limit)
        let extraLabel = plan.bonusTooltip

        return UsageData(
            sessionPct: totalPercent,
            sessionResetMins: resetMins,
            sessionEpoch: periodEndEpoch,
            weeklyPct: totalPercent,
            weeklyResetMins: resetMins,
            weeklyEpoch: periodEndEpoch,
            status: status,
            representativeClaim: .unknown,
            updatedAt: now,
            organizationID: includedLabel,
            cursorQuota: UsageData.CursorQuota(
                totalPct: totalPercent,
                autoPct: autoPercent,
                apiPct: apiPercent,
                resetMins: resetMins,
                resetEpoch: periodEndEpoch,
                includedUsageLabel: includedLabel,
                extraUsageLabel: extraLabel
            )
        )
    }

    /// Decode the full gRPC-Web body (message frame + trailer frame) into
    /// a `UsageData`. Exposed `internal` for fixture tests.
    static func parseGetCurrentPeriodUsage(grpcWebBody data: Data, now: Date) throws -> UsageData {
        let frames = parseGRPCWebFrames(data)
        // Find the first message frame (trailer frames have the 0x80 flag).
        guard let payload = frames.first(where: { $0.isTrailer == false })?.body else {
            // Check trailer for an explicit grpc-status if present.
            if let trailer = frames.first(where: { $0.isTrailer })?.body,
               let trailerText = String(data: trailer, encoding: .utf8) {
                throw AISourceError.dataSourceContractViolation(
                    detail: "Cursor returned no message frame; trailer: \(trailerText.prefix(180))"
                )
            }
            throw AISourceError.dataSourceContractViolation(detail: "Cursor returned no frames")
        }

        // Schema (reverse-engineered from a live free-tier capture):
        //   field 1: period_start_ms (varint, int64, unix epoch milliseconds)
        //   field 2: period_end_ms   (varint, int64)
        //   field 3 { … }            (free-credit promo blob — has explainer string at field 7)
        //   field 4 { … }            (per-bucket usage tallies; user vs system buckets)
        //   field 5: included_usage_count (varint, e.g. 200 for free)
        //   field 7: percent_used_summary string ("You've used 0% of your included usage")
        //   field 11: percent_total_summary string
        //   field 12: percent_api_summary string
        //   field 13: repeated string (model names available on this plan)
        var reader = CursorProtoReader(bytes: payload)
        _ = reader.findVarint(field: 1)
        reader.reset()
        let periodEndMs = reader.findVarint(field: 2) ?? 0
        reader.reset()
        let includedUsage = reader.findVarint(field: 5)
        reader.reset()
        let extraUsageSummary: String? = {
            guard let promoBlob = reader.findLengthDelimited(field: 3) else { return nil }
            var nested = CursorProtoReader(bytes: promoBlob)
            return nested.findString(field: 7)
        }()
        reader.reset()
        let autoPercentSummary = reader.findString(field: 7) ?? ""
        reader.reset()
        let totalPercentSummary = reader.findString(field: 11) ?? ""
        reader.reset()
        let apiPercentSummary = reader.findString(field: 12) ?? ""

        let periodEndEpoch = Int(periodEndMs / 1000)
        let nowEpoch = Int(now.timeIntervalSince1970)
        let resetMins = max(0, (periodEndEpoch - nowEpoch + 59) / 60)

        // Parse "You've used X% of your included usage" → X.
        // Cursor's current dashboard reports separate monthly buckets:
        // Total (field 11), Auto (field 7), API (field 12). Older
        // captures only had field 7, so the legacy fields mirror Total
        // when present and fall back to Auto otherwise.
        let summaries = [autoPercentSummary, totalPercentSummary, apiPercentSummary]
        let autoPercent = Self.parseLabeledPercent(labels: ["Auto", "Auto + Composer"], from: summaries)
            ?? Self.parsePercent(from: autoPercentSummary)
        let totalPercent = Self.parsePercent(from: totalPercentSummary) ?? autoPercent ?? 0
        let apiPercent = Self.parseLabeledPercent(labels: ["API"], from: summaries)
            ?? Self.parsePercent(from: apiPercentSummary)

        // Status: resets_at in past → .notStarted (between billing periods,
        // shouldn't really happen since Cursor extends them automatically,
        // but defensive); otherwise .allowed when authenticated. We don't
        // surface a separate weekly window — Cursor's billing period IS
        // the only window, so mirror it into both slots so the UI's
        // weekly row reads the same percent rather than 0.
        let status: UsageData.Status = (periodEndEpoch <= nowEpoch) ? .notStarted : .allowed

        // Plan badge: derive from included_usage count when present. Free
        // tier shows ~200 fast requests/mo; Pro shows ~500 etc. We don't
        // pretend to know the exact mapping — surface the raw included
        // count via organizationID so the UI can label "200 / period".
        let planBadge: String? = {
            guard let n = includedUsage else { return nil }
            return "\(n) included / period"
        }()

        return UsageData(
            sessionPct: totalPercent,
            sessionResetMins: resetMins,
            sessionEpoch: periodEndEpoch,
            weeklyPct: totalPercent,
            weeklyResetMins: resetMins,
            weeklyEpoch: periodEndEpoch,
            status: status,
            representativeClaim: .unknown,
            updatedAt: now,
            organizationID: planBadge,
            cursorQuota: UsageData.CursorQuota(
                totalPct: totalPercent,
                autoPct: autoPercent,
                apiPct: apiPercent,
                resetMins: resetMins,
                resetEpoch: periodEndEpoch,
                includedUsageLabel: planBadge,
                extraUsageLabel: extraUsageSummary
            )
        )
    }

    /// "You've used 12% of your included usage" → 12.
    /// Returns nil when the string doesn't match the expected shape.
    private static func parsePercent(from summary: String) -> Int? {
        // Cheap regex: find the first integer immediately followed by %.
        guard let range = summary.range(of: "[0-9]+(?=%)", options: .regularExpression) else {
            return nil
        }
        return Int(summary[range])
    }

    private static func percentInt(_ value: Double?) -> Int? {
        guard let value, value.isFinite else { return nil }
        return max(0, Int(value.rounded()))
    }

    private static func parseMillis(_ value: String) -> Int64? {
        if let exact = Int64(value) { return exact }
        guard let decimal = Double(value), decimal.isFinite else { return nil }
        return Int64(decimal)
    }

    private static func includedSpendLabel(includedSpend: Double?, limit: Double?) -> String? {
        guard let cents = [includedSpend, limit].compactMap({ $0 }).first(where: { $0 > 0 }) else {
            return nil
        }
        return "\(formatCents(cents)) included / period"
    }

    private static func formatCents(_ value: Double) -> String {
        let cents = Int(value.rounded())
        let dollars = Double(cents) / 100
        if cents % 100 == 0 {
            return "$\(cents / 100)"
        }
        return String(format: "$%.2f", dollars)
    }

    /// Parses shapes Cursor has used in the dashboard summary, including:
    ///   - "25% Auto and 95% API used"
    ///   - "Auto 25% used"
    ///   - "You've used 0% of your included API usage"
    private static func parseLabeledPercent(labels: [String], from summaries: [String]) -> Int? {
        for summary in summaries where !summary.isEmpty {
            for label in labels {
                let escaped = NSRegularExpression.escapedPattern(for: label)
                let beforePatterns = [
                    #"([0-9]+)\s*%\s*"# + escaped,
                    #"([0-9]+)\s*%\s+of\s+your\s+included\s+"# + escaped
                ]
                let afterPatterns = [
                    escaped + #"\D{0,40}([0-9]+)\s*%"#
                ]
                for pattern in beforePatterns + afterPatterns {
                    if let value = firstRegexInt(in: summary, pattern: pattern) {
                        return value
                    }
                }
            }
        }
        return nil
    }

    private static func firstRegexInt(in text: String, pattern: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: nsRange),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return Int(text[range])
    }

    private struct CursorConnectUsageResponse: Decodable {
        let billingCycleEnd: String?
        let autoModelSelectedDisplayMessage: String?
        let namedModelSelectedDisplayMessage: String?
        let planUsage: CursorConnectPlanUsage?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: DynamicCodingKey.self)
            billingCycleEnd = Self.decodeString(c, aliases: [
                "billingCycleEnd", "billing_cycle_end", "periodEnd", "period_end", "currentPeriodEnd"
            ])
            autoModelSelectedDisplayMessage = Self.decodeString(c, aliases: [
                "autoModelSelectedDisplayMessage",
                "auto_model_selected_display_message",
                "autoDisplayMessage",
                "autoUsageDisplayMessage",
                "autoUsageMessage"
            ])
            namedModelSelectedDisplayMessage = Self.decodeString(c, aliases: [
                "namedModelSelectedDisplayMessage",
                "named_model_selected_display_message",
                "apiDisplayMessage",
                "apiUsageDisplayMessage",
                "namedUsageDisplayMessage"
            ])
            planUsage = Self.decodePlanUsage(c, aliases: ["planUsage", "plan_usage"])
        }

        private static func decodeString(_ c: KeyedDecodingContainer<DynamicCodingKey>, aliases: [String]) -> String? {
            for alias in aliases {
                let key = DynamicCodingKey(alias)
                if let string = try? c.decodeIfPresent(String.self, forKey: key) { return string }
                if let int = try? c.decodeIfPresent(Int64.self, forKey: key) { return String(int) }
                if let double = try? c.decodeIfPresent(Double.self, forKey: key) { return String(double) }
            }
            return nil
        }

        private static func decodePlanUsage(
            _ c: KeyedDecodingContainer<DynamicCodingKey>,
            aliases: [String]
        ) -> CursorConnectPlanUsage? {
            for alias in aliases {
                if let plan = try? c.decodeIfPresent(CursorConnectPlanUsage.self, forKey: DynamicCodingKey(alias)) {
                    return plan
                }
            }
            return nil
        }
    }

    private struct CursorConnectPlanUsage: Decodable {
        let apiPercentUsed: Double?
        let autoPercentUsed: Double?
        let totalPercentUsed: Double?
        let totalDisplayMessage: String?
        let autoDisplayMessage: String?
        let apiDisplayMessage: String?
        let bonusTooltip: String?
        let includedSpend: Double?
        let limit: Double?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: DynamicCodingKey.self)
            apiPercentUsed = Self.decodeDouble(c, aliases: [
                "apiPercentUsed", "api_percent_used", "apiUsagePercent", "api_usage_percent", "apiPercent"
            ])
            autoPercentUsed = Self.decodeDouble(c, aliases: [
                "autoPercentUsed", "auto_percent_used", "autoUsagePercent", "auto_usage_percent",
                "autoModelPercentUsed", "auto_model_percent_used", "autoModelPercent", "autoPercent"
            ])
            totalPercentUsed = Self.decodeDouble(c, aliases: [
                "totalPercentUsed", "total_percent_used", "totalUsagePercent", "total_usage_percent", "totalPercent"
            ])
            totalDisplayMessage = Self.decodeString(c, aliases: [
                "totalDisplayMessage", "totalUsageDisplayMessage", "totalMessage"
            ])
            autoDisplayMessage = Self.decodeString(c, aliases: [
                "autoDisplayMessage", "autoUsageDisplayMessage", "autoMessage", "autoModelDisplayMessage"
            ])
            apiDisplayMessage = Self.decodeString(c, aliases: [
                "apiDisplayMessage", "apiUsageDisplayMessage", "apiMessage"
            ])
            bonusTooltip = Self.decodeString(c, aliases: ["bonusTooltip", "bonus_tooltip"])
            includedSpend = Self.decodeDouble(c, aliases: ["includedSpend", "included_spend"])
            limit = Self.decodeDouble(c, aliases: ["limit", "includedLimit", "included_limit"])
        }

        private static func decodeDouble(
            _ c: KeyedDecodingContainer<DynamicCodingKey>,
            aliases: [String]
        ) -> Double? {
            for alias in aliases {
                let key = DynamicCodingKey(alias)
                if let double = try? c.decodeIfPresent(Double.self, forKey: key) { return double }
                if let int = try? c.decodeIfPresent(Int.self, forKey: key) { return Double(int) }
                if let string = try? c.decodeIfPresent(String.self, forKey: key) { return Double(string) }
            }
            return nil
        }

        private static func decodeString(
            _ c: KeyedDecodingContainer<DynamicCodingKey>,
            aliases: [String]
        ) -> String? {
            for alias in aliases {
                if let string = try? c.decodeIfPresent(String.self, forKey: DynamicCodingKey(alias)) {
                    return string
                }
            }
            return nil
        }
    }

    private struct DynamicCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int?

        init(_ stringValue: String) {
            self.stringValue = stringValue
            self.intValue = nil
        }

        init?(stringValue: String) {
            self.init(stringValue)
        }

        init?(intValue: Int) {
            self.stringValue = String(intValue)
            self.intValue = intValue
        }
    }

    // MARK: - gRPC-Web framing

    fileprivate struct Frame {
        let isTrailer: Bool
        let body: Data
    }

    /// Walks a gRPC-Web body, returning each frame separately. Each frame
    /// is a 1-byte flags + 4-byte big-endian length + N-byte body. Flag
    /// bit 0x80 indicates a trailer frame (HTTP-headers-style key:value
    /// pairs CRLF-separated, containing `grpc-status:` etc.).
    fileprivate static func parseGRPCWebFrames(_ data: Data) -> [Frame] {
        var frames: [Frame] = []
        var i = 0
        while i + 5 <= data.count {
            let flags = data[i]
            // Big-endian uint32 length.
            let length = (Int(data[i + 1]) << 24) | (Int(data[i + 2]) << 16) | (Int(data[i + 3]) << 8) | Int(data[i + 4])
            let start = i + 5
            let end = start + length
            guard end <= data.count else { break }
            frames.append(Frame(isTrailer: (flags & 0x80) != 0, body: data.subdata(in: start..<end)))
            i = end
        }
        return frames
    }
}

// MARK: - Minimal protobuf reader

/// Forward-only varint/length-delimited proto walker used by
/// `CursorSource.parseGetCurrentPeriodUsage`. Kept file-private so it
/// doesn't shadow the other tiny proto readers elsewhere in Shared
/// (each provider has its own targeted reader rather than a vendored
/// general-purpose proto runtime).
private struct CursorProtoReader {
    let bytes: Data
    var index: Int

    init(bytes: Data) {
        // Normalize to zero-based indexing — slices preserve parent index.
        self.bytes = Data(bytes)
        self.index = 0
    }

    mutating func reset() { index = 0 }

    mutating func findVarint(field: Int) -> UInt64? {
        while index < bytes.endIndex {
            guard let (n, w) = readTag() else { return nil }
            if w == 0 {
                guard let v = readVarint() else { return nil }
                if n == field { return v }
            } else if !skip(wireType: w) {
                return nil
            }
        }
        return nil
    }

    mutating func findLengthDelimited(field: Int) -> Data? {
        while index < bytes.endIndex {
            guard let (n, w) = readTag() else { return nil }
            if w == 2 {
                guard let len = readVarint() else { return nil }
                let count = Int(len)
                guard index + count <= bytes.endIndex else { return nil }
                let slice = bytes.subdata(in: index..<(index + count))
                index += count
                if n == field { return slice }
            } else if !skip(wireType: w) {
                return nil
            }
        }
        return nil
    }

    mutating func findString(field: Int) -> String? {
        guard let d = findLengthDelimited(field: field) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    private mutating func readTag() -> (Int, Int)? {
        guard let raw = readVarint() else { return nil }
        return (Int(raw >> 3), Int(raw & 0x07))
    }

    private mutating func readVarint() -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while index < bytes.endIndex {
            let b = bytes[index]
            index += 1
            result |= UInt64(b & 0x7f) << shift
            if (b & 0x80) == 0 { return result }
            shift += 7
            if shift > 63 { return nil }
        }
        return nil
    }

    private mutating func skip(wireType: Int) -> Bool {
        switch wireType {
        case 0: return readVarint() != nil
        case 1:
            guard index + 8 <= bytes.endIndex else { return false }
            index += 8; return true
        case 2:
            guard let len = readVarint() else { return false }
            let count = Int(len)
            guard index + count <= bytes.endIndex else { return false }
            index += count; return true
        case 5:
            guard index + 4 <= bytes.endIndex else { return false }
            index += 4; return true
        default: return false
        }
    }
}
#endif // os(macOS)

#if os(macOS)
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(OSLog)
import OSLog
#endif

/// Live usage source for Cursor's CLI/IDE account.
///
/// Calls `https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage`
/// as gRPC-Web with a JWT bearer (read from the macOS Keychain by
/// `CursorTokenProvider`) and maps the response into a `UsageData` the
/// rest of the Mac app already knows how to render.
///
/// **Why gRPC-Web instead of plain gRPC**: cursor-agent's JS bundle binds
/// the same handler at `api2.cursor.sh` to `application/grpc-web+proto`
/// content type (the Connect protocol family). A plain `application/grpc`
/// POST gets HTTP/2 464 (AWS ELB rejects); gRPC-Web framed POST returns
/// the proto payload + trailer correctly.
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

    // MARK: - Parser

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
        let periodStartMs = reader.findVarint(field: 1) ?? 0
        reader.reset()
        let periodEndMs = reader.findVarint(field: 2) ?? 0
        reader.reset()
        let includedUsage = reader.findVarint(field: 5)
        reader.reset()
        let percentSummary = reader.findString(field: 7) ?? ""

        let periodEndEpoch = Int(periodEndMs / 1000)
        let nowEpoch = Int(now.timeIntervalSince1970)
        let resetMins = max(0, (periodEndEpoch - nowEpoch + 59) / 60)

        // Parse "You've used X% of your included usage" → X.
        let percent = Self.parsePercent(from: percentSummary) ?? 0

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
            sessionPct: percent,
            sessionResetMins: resetMins,
            sessionEpoch: periodEndEpoch,
            weeklyPct: percent,
            weeklyResetMins: resetMins,
            weeklyEpoch: periodEndEpoch,
            status: status,
            representativeClaim: .fiveHour,
            updatedAt: now,
            organizationID: planBadge
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

#if os(macOS)
import Foundation
#if canImport(OSLog)
import OSLog
#endif

/// Fetches Cursor billing usage from the same dashboard API the Cursor website
/// uses for spend analytics.
///
/// Local hook logs, agent transcripts, and KV blobs only approximate token
/// volume and price it through OpenRouter aliases. Cursor's dashboard exposes
/// per-event `chargedCents` via `GetFilteredUsageEvents`; that is the source
/// of truth for dollar spend in Analytics.
public enum CursorDashboardUsageParser {

    public static let defaultEndpoint = URL(
        string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetFilteredUsageEvents"
    )!
    public static let defaultPageSize = 1_000
    public static let defaultCacheTTL: TimeInterval = 300

    private static let logger = Logger(subsystem: "com.clawdmeter.shared", category: "CursorDashboardUsage")

    // MARK: - Public API

    /// Load Cursor dashboard usage records, preferring a fresh on-disk cache.
    public static func loadRecords(
        tokenProvider: CursorTokenProvider = CursorTokenProvider(),
        urlSession: URLSession = .shared,
        endpoint: URL = defaultEndpoint,
        cacheURL: URL? = defaultCacheURL(),
        cacheTTL: TimeInterval = defaultCacheTTL,
        now: Date = Date()
    ) async -> [UsageRecord] {
        if let cacheURL,
           let cached = readCache(at: cacheURL, maxAge: cacheTTL, now: now) {
            return usageRecords(from: cached)
        }

        guard let token = tokenProvider.currentAccessToken else {
            if let cacheURL, let cached = readCache(at: cacheURL, maxAge: .infinity, now: now) {
                return usageRecords(from: cached)
            }
            return []
        }

        do {
            let records = try await fetchRecords(
                token: token,
                urlSession: urlSession,
                endpoint: endpoint
            )
            if let cacheURL, !records.isEmpty {
                writeCache(records: records, fetchedAt: now, to: cacheURL)
            }
            return records
        } catch {
            logger.warning("Cursor dashboard usage fetch failed: \(String(describing: error), privacy: .public)")
            if let cacheURL, let cached = readCache(at: cacheURL, maxAge: .infinity, now: now) {
                return usageRecords(from: cached)
            }
            return []
        }
    }

    public static func defaultCacheURL() -> URL? {
        guard let root = UsageStore.containerURL else { return nil }
        return root
            .appendingPathComponent("analytics", isDirectory: true)
            .appendingPathComponent("cursor-dashboard-usage.json")
    }

    public static func cacheMtime(url: URL? = defaultCacheURL()) -> Date? {
        guard let url else { return nil }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return attrs[.modificationDate] as? Date
    }

    // MARK: - Network

    static func fetchRecords(
        token: String,
        urlSession: URLSession,
        endpoint: URL,
        pageSize: Int = defaultPageSize
    ) async throws -> [UsageRecord] {
        var page = 1
        var allEvents: [UsageEventDisplay] = []
        var expectedTotal: Int?

        while page <= 128 {
            let response = try await fetchPage(
                token: token,
                urlSession: urlSession,
                endpoint: endpoint,
                page: page,
                pageSize: pageSize
            )
            if expectedTotal == nil {
                expectedTotal = response.totalUsageEventsCount
            }
            let batch = response.usageEventsDisplay
            guard !batch.isEmpty else { break }
            allEvents.append(contentsOf: batch)
            if let expectedTotal, allEvents.count >= expectedTotal { break }
            if batch.count < pageSize { break }
            page += 1
        }

        return parseEvents(allEvents)
    }

    static func fetchPage(
        token: String,
        urlSession: URLSession,
        endpoint: URL,
        page: Int,
        pageSize: Int
    ) async throws -> FilteredUsageEventsResponse {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(
            FilteredUsageEventsRequest(page: page, pageSize: pageSize)
        )

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FetchError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw FetchError.unauthenticated
            }
            throw FetchError.httpStatus(http.statusCode)
        }

        return try JSONDecoder().decode(FilteredUsageEventsResponse.self, from: data)
    }

    // MARK: - Parsing

    static func parseEvents(_ events: [UsageEventDisplay]) -> [UsageRecord] {
        events.compactMap(parseEvent)
    }

    static func parseEvent(_ event: UsageEventDisplay) -> UsageRecord? {
        guard let timestampMs = event.timestamp.flatMap({ Int64($0) }),
              timestampMs > 0 else {
            return nil
        }

        let tokenUsage = event.tokenUsage
        let inputTokens = max(0, tokenUsage?.inputTokens ?? 0)
        let outputTokens = max(0, tokenUsage?.outputTokens ?? 0)
        let cacheReadTokens = max(0, tokenUsage?.cacheReadTokens ?? 0)
        let cacheWriteTokens = max(0, tokenUsage?.cacheWriteTokens ?? 0)
        let totalTokens = inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens

        let cents = event.chargedCents
            ?? tokenUsage?.totalCents
            ?? 0
        let costUSD = Decimal(string: String(format: "%.10f", cents / 100)) ?? 0
        guard totalTokens > 0 || costUSD > 0 else {
            return nil
        }

        let model = event.model?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? event.model!.trimmingCharacters(in: .whitespacesAndNewlines)
            : "cursor-auto"

        let timestamp = Date(timeIntervalSince1970: TimeInterval(timestampMs) / 1000)
        let dedupKey = [
            "cursor-dashboard",
            String(timestampMs),
            model,
            String(inputTokens),
            String(outputTokens),
            String(cacheReadTokens),
            String(cacheWriteTokens),
            String(format: "%.4f", cents)
        ].joined(separator: ":")

        return UsageRecord(
            provider: .cursor,
            timestamp: timestamp,
            model: model,
            tokens: TokenTotals(
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheCreationTokens: cacheWriteTokens,
                cacheReadTokens: cacheReadTokens,
                costUSD: costUSD,
                requestCount: 1
            ),
            repo: nil,
            dedupKey: dedupKey
        )
    }

    // MARK: - Cache

    struct CachePayload: Codable, Sendable {
        let fetchedAt: Date
        let records: [CachedUsageRecord]
    }

    struct CachedUsageRecord: Codable, Sendable {
        let timestamp: Date
        let model: String
        let inputTokens: Int
        let outputTokens: Int
        let cacheCreationTokens: Int
        let cacheReadTokens: Int
        let costUSD: Decimal
        let dedupKey: String
    }

    static func readCache(at url: URL, maxAge: TimeInterval, now: Date) -> CachePayload? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let payload = try? JSONDecoder().decode(CachePayload.self, from: data) else {
            return nil
        }
        guard now.timeIntervalSince(payload.fetchedAt) <= maxAge else {
            return nil
        }
        return payload
    }

    static func writeCache(records: [UsageRecord], fetchedAt: Date, to url: URL) {
        let payload = CachePayload(
            fetchedAt: fetchedAt,
            records: records.map {
                CachedUsageRecord(
                    timestamp: $0.timestamp,
                    model: $0.model,
                    inputTokens: $0.tokens.inputTokens,
                    outputTokens: $0.tokens.outputTokens,
                    cacheCreationTokens: $0.tokens.cacheCreationTokens,
                    cacheReadTokens: $0.tokens.cacheReadTokens,
                    costUSD: $0.tokens.costUSD,
                    dedupKey: $0.dedupKey ?? UUID().uuidString
                )
            }
        )
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(payload)
            try data.write(to: url, options: .atomic)
        } catch {
            logger.warning("Cursor dashboard usage cache write failed: \(String(describing: error), privacy: .public)")
        }
    }

    static func usageRecords(from payload: CachePayload) -> [UsageRecord] {
        payload.records.map {
            UsageRecord(
                provider: .cursor,
                timestamp: $0.timestamp,
                model: $0.model,
                tokens: TokenTotals(
                    inputTokens: $0.inputTokens,
                    outputTokens: $0.outputTokens,
                    cacheCreationTokens: $0.cacheCreationTokens,
                    cacheReadTokens: $0.cacheReadTokens,
                    costUSD: $0.costUSD,
                    requestCount: 1
                ),
                repo: nil,
                dedupKey: $0.dedupKey
            )
        }
    }

    // MARK: - Wire types

    struct FilteredUsageEventsRequest: Encodable {
        let page: Int
        let pageSize: Int
    }

    struct FilteredUsageEventsResponse: Decodable {
        let totalUsageEventsCount: Int?
        let usageEventsDisplay: [UsageEventDisplay]
    }

    struct UsageEventDisplay: Decodable {
        let timestamp: String?
        let model: String?
        let chargedCents: Double?
        let tokenUsage: TokenUsage?

        enum CodingKeys: String, CodingKey {
            case timestamp
            case model
            case chargedCents
            case tokenUsage
        }
    }

    struct TokenUsage: Decodable {
        let inputTokens: Int?
        let outputTokens: Int?
        let cacheReadTokens: Int?
        let cacheWriteTokens: Int?
        let totalCents: Double?
    }

    enum FetchError: Error {
        case invalidResponse
        case unauthenticated
        case httpStatus(Int)
    }
}
#endif

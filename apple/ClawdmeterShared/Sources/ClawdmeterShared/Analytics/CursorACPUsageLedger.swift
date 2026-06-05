import Foundation

public struct CursorACPUsageLedgerRecord: Codable, Sendable, Equatable {
    public enum Surface: String, Codable, Sendable {
        case chat
        case code
    }

    public let timestamp: Date
    public let surface: Surface
    public let sessionId: UUID
    public let externalSessionId: String?
    public let repo: String?
    public let model: String
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let totalTokens: Int?
    public let costUSD: Decimal?
    public let requestCount: Int

    public init(
        timestamp: Date = Date(),
        surface: Surface,
        sessionId: UUID,
        externalSessionId: String?,
        repo: String?,
        model: String?,
        inputTokens: Int?,
        outputTokens: Int?,
        totalTokens: Int?,
        costUSD: Decimal? = nil,
        requestCount: Int = 1
    ) {
        self.timestamp = timestamp
        self.surface = surface
        self.sessionId = sessionId
        self.externalSessionId = externalSessionId
        self.repo = repo?.isEmpty == false ? repo : nil
        self.model = model?.isEmpty == false ? model! : "cursor"
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
        self.costUSD = costUSD
        self.requestCount = requestCount
    }

    public var usageRecord: UsageRecord {
        let splitTotal = (inputTokens ?? 0) + (outputTokens ?? 0)
        let fallbackInput = splitTotal == 0 ? (totalTokens ?? 0) : 0
        return UsageRecord(
            provider: .cursor,
            timestamp: timestamp,
            model: model,
            tokens: TokenTotals(
                inputTokens: inputTokens ?? fallbackInput,
                outputTokens: outputTokens ?? 0,
                costUSD: costUSD ?? 0,
                requestCount: max(1, requestCount)
            ),
            repo: repo,
            dedupKey: "cursor-acp:\(sessionId.uuidString):\(Int(timestamp.timeIntervalSince1970 * 1000)):\(inputTokens ?? -1):\(outputTokens ?? -1):\(totalTokens ?? -1)"
        )
    }
}

public enum CursorACPUsageLedger {
    public static func defaultURL() -> URL? {
        guard let root = UsageStore.containerURL else { return nil }
        return root
            .appendingPathComponent("analytics", isDirectory: true)
            .appendingPathComponent("cursor-acp-usage.jsonl")
    }

    public static func append(_ record: CursorACPUsageLedgerRecord, url: URL? = nil) {
        guard let url = url ?? defaultURL() else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var data = try encoder.encode(record)
            data.append(0x0A)
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: url, options: .atomic)
            }
            NotificationCenter.default.post(
                name: .cursorUsageRecorded,
                object: nil,
                userInfo: ["record": record.usageRecord]
            )
        } catch {
            // Best-effort analytics: never disrupt the live Cursor turn.
        }
    }

    public static func parseFile(at url: URL? = nil) -> [UsageRecord] {
        guard let url = url ?? defaultURL(),
              let data = try? Data(contentsOf: url),
              !data.isEmpty
        else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data
            .split(separator: 0x0A, omittingEmptySubsequences: true)
            .compactMap { line -> UsageRecord? in
                guard let record = try? decoder.decode(CursorACPUsageLedgerRecord.self, from: Data(line)) else {
                    return nil
                }
                return record.usageRecord
            }
    }

    public static func mostRecentMtime(url: URL? = nil) -> Date? {
        guard let url = url ?? defaultURL(),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        else { return nil }
        return attrs[.modificationDate] as? Date
    }
}

public extension Notification.Name {
    static let cursorUsageRecorded = Notification.Name("clawdmeter.cursor.usage.recorded")
}

import Foundation
import Darwin

/// Continuum-owned Grok usage ledger.
///
/// Grok does not expose a verified account quota API in this app today, so this
/// file is deliberately not part of the live `/usage` quota envelope. It stores
/// only usage events observed by Continuum's Grok harness and is folded into
/// analytics history by `UsageHistoryLoader`.
public enum GrokUsageLedger {
    public struct Entry: Codable, Sendable, Equatable {
        public var version: Int
        public var timestamp: Date
        public var sessionId: String
        public var repo: String?
        public var model: String
        public var inputTokens: Int
        public var outputTokens: Int
        public var totalTokens: Int
        public var dedupKey: String

        public init(
            version: Int = 1,
            timestamp: Date = Date(),
            sessionId: String,
            repo: String?,
            model: String = "grok-build",
            inputTokens: Int,
            outputTokens: Int,
            totalTokens: Int,
            dedupKey: String
        ) {
            self.version = version
            self.timestamp = timestamp
            self.sessionId = sessionId
            self.repo = repo
            self.model = model.isEmpty ? "grok-build" : model
            self.inputTokens = max(0, inputTokens)
            self.outputTokens = max(0, outputTokens)
            self.totalTokens = max(0, totalTokens)
            self.dedupKey = dedupKey
        }

        public init?(
            usage: HarnessUsage,
            sessionId: String,
            repo: String?,
            model: String?,
            sequence: UInt64,
            timestamp: Date = Date()
        ) {
            let explicitInput = max(0, usage.inputTokens ?? 0)
            let explicitOutput = max(0, usage.outputTokens ?? 0)
            let explicitTotal = max(0, usage.totalTokens ?? 0)
            let summed = explicitInput + explicitOutput
            let total = max(explicitTotal, summed)
            guard total > 0 else { return nil }

            let input: Int
            let output: Int
            if summed > 0 {
                input = explicitInput
                output = explicitOutput
            } else {
                input = total
                output = 0
            }

            let modelName = (model?.isEmpty == false) ? model! : "grok-build"
            self.init(
                timestamp: timestamp,
                sessionId: sessionId,
                repo: repo,
                model: modelName,
                inputTokens: input,
                outputTokens: output,
                totalTokens: total,
                dedupKey: "grok:\(sessionId):\(sequence)"
            )
        }

        public func usageRecord() -> UsageRecord? {
            let input = max(0, inputTokens)
            let output = max(0, outputTokens)
            let explicitTotal = max(0, totalTokens)
            let splitTotal = input + output
            let tokenTotal = max(explicitTotal, splitTotal)
            guard tokenTotal > 0 else { return nil }

            let tokens: TokenTotals
            if splitTotal > 0 {
                tokens = TokenTotals(
                    inputTokens: input,
                    outputTokens: output,
                    reasoningTokens: max(0, tokenTotal - splitTotal),
                    requestCount: 1
                )
            } else {
                tokens = TokenTotals(inputTokens: tokenTotal, requestCount: 1)
            }

            return UsageRecord(
                provider: .grok,
                timestamp: timestamp,
                model: model.isEmpty ? "grok-build" : model,
                tokens: tokens,
                repo: repo,
                dedupKey: dedupKey.isEmpty ? nil : dedupKey
            )
        }
    }

    public static func defaultURL() -> URL? {
        guard let root = UsageStore.containerURL else { return nil }
        return root
            .appendingPathComponent("analytics", isDirectory: true)
            .appendingPathComponent("grok-usage.jsonl")
    }

    public static func append(_ entry: Entry, to url: URL? = nil) throws {
        guard let url = url ?? defaultURL() else { return }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(entry)
        data.append(0x0A)

        try appendLocked(data, to: url)
    }

    public static func records(from url: URL) -> [UsageRecord] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data
            .split(separator: 0x0A, omittingEmptySubsequences: true)
            .compactMap { line in
                guard let entry = try? decoder.decode(Entry.self, from: Data(line)) else { return nil }
                return entry.usageRecord()
            }
    }

    private static func appendLocked(_ data: Data, to url: URL) throws {
        let flags = O_WRONLY | O_CREAT | O_APPEND
        let mode = mode_t(S_IRUSR | S_IWUSR)
        let fd = url.path.withCString { path in
            open(path, flags, mode)
        }
        guard fd >= 0 else { throw POSIXError(currentPOSIXErrorCode()) }
        defer { _ = close(fd) }

        guard flock(fd, LOCK_EX) == 0 else {
            throw POSIXError(currentPOSIXErrorCode())
        }
        defer { _ = flock(fd, LOCK_UN) }

        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = write(fd, base.advanced(by: offset), buffer.count - offset)
                if written < 0 {
                    if currentErrno() == EINTR { continue }
                    throw POSIXError(currentPOSIXErrorCode())
                }
                guard written > 0 else { throw POSIXError(.EIO) }
                offset += written
            }
        }
    }

    private static func currentPOSIXErrorCode() -> POSIXErrorCode {
        POSIXErrorCode(rawValue: currentErrno()) ?? .EIO
    }

    private static func currentErrno() -> Int32 {
        Darwin.errno
    }
}

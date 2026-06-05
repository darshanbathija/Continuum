import Foundation

/// Reads Grok CLI session metadata from `~/.grok/sessions`.
///
/// Grok's CLI does not expose a stable numeric account quota endpoint here, but
/// each session writes `signals.json` with the same context-limit numbers the
/// TUI surfaces (`contextTokensUsed` / `contextWindowTokens`). These records
/// make normal Grok CLI usage visible in token analytics instead of only
/// counting Continuum-owned harness ledger rows.
public enum GrokCLIUsageParser {
    private struct Signals: Decodable {
        var turnCount: Int?
        var assistantMessageCount: Int?
        var totalTokensBeforeCompaction: Int?
        var contextTokensUsed: Int?
        var contextWindowTokens: Int?
        var primaryModelId: String?
        var modelsUsed: [String]?
    }

    public struct ContextLimit: Codable, Sendable, Equatable {
        public let usedTokens: Int
        public let limitTokens: Int
        public let timestamp: Date
        public let model: String
        public let repo: RepoKey?
        public let sessionId: String

        public var percent: Double {
            guard limitTokens > 0 else { return 0 }
            return max(0, min(100, Double(usedTokens) / Double(limitTokens) * 100))
        }

        public var roundedPercent: Int {
            Int(percent.rounded())
        }
    }

    public static func defaultSessionsDir(home: URL = ClawdmeterRealHome.url()) -> URL? {
        let dir = home.appendingPathComponent(".grok/sessions", isDirectory: true)
        return FileManager.default.fileExists(atPath: dir.path) ? dir : nil
    }

    public static func parseSessions(root: URL) -> [UsageRecord] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else { return [] }

        var records: [UsageRecord] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent == "signals.json" else { continue }
            records.append(contentsOf: parseUsageRecords(at: url))
        }
        return records
    }

    public static func parseContextLimits(root: URL) -> [ContextLimit] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else { return [] }

        var limits: [ContextLimit] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent == "signals.json" else { continue }
            guard let limit = parseContextLimit(at: url) else { continue }
            limits.append(limit)
        }
        return limits
    }

    public static func latestContextLimit(root: URL) -> ContextLimit? {
        parseContextLimits(root: root).max { lhs, rhs in
            lhs.timestamp < rhs.timestamp
        }
    }

    public static func parseSignals(at url: URL) -> UsageRecord? {
        parseUsageRecords(at: url).first
    }

    public static func parseUsageRecords(at url: URL) -> [UsageRecord] {
        guard let data = try? Data(contentsOf: url),
              let signals = try? JSONDecoder().decode(Signals.self, from: data)
        else { return [] }

        let contextTokens = max(0, signals.contextTokensUsed ?? 0)
        let preCompactionTokens = max(0, signals.totalTokensBeforeCompaction ?? 0)
        let totalTokens = contextTokens + preCompactionTokens
        guard totalTokens > 0 else { return [] }

        let sessionDir = url.deletingLastPathComponent()
        let sessionId = sessionDir.lastPathComponent
        let encodedCwd = sessionDir.deletingLastPathComponent().lastPathComponent
        let decodedCwd = encodedCwd.removingPercentEncoding
        let repo = decodedCwd.map(RepoIdentity.normalize)
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        let mtime = values?.contentModificationDate ?? Date()
        let models = resolvedModels(from: signals)
        let tokenSplits = split(totalTokens, into: models.count)
        let requestCount = max(1, signals.turnCount ?? signals.assistantMessageCount ?? 1)
        let requestSplits = split(requestCount, into: models.count)

        return models.enumerated().map { index, model in
            UsageRecord(
                provider: .grok,
                timestamp: mtime,
                model: model,
                tokens: TokenTotals(inputTokens: tokenSplits[index], requestCount: requestSplits[index]),
                repo: repo,
                dedupKey: dedupKey(sessionId: sessionId, model: model, modelCount: models.count)
            )
        }
    }

    public static func parseContextLimit(at url: URL) -> ContextLimit? {
        guard let data = try? Data(contentsOf: url),
              let signals = try? JSONDecoder().decode(Signals.self, from: data)
        else { return nil }

        let used = max(0, signals.contextTokensUsed ?? 0)
        let limit = max(0, signals.contextWindowTokens ?? 0)
        guard limit > 0 else { return nil }

        let sessionDir = url.deletingLastPathComponent()
        let sessionId = sessionDir.lastPathComponent
        let encodedCwd = sessionDir.deletingLastPathComponent().lastPathComponent
        let decodedCwd = encodedCwd.removingPercentEncoding
        let repo = decodedCwd.map(RepoIdentity.normalize)
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        let mtime = values?.contentModificationDate ?? Date()

        return ContextLimit(
            usedTokens: used,
            limitTokens: limit,
            timestamp: mtime,
            model: resolvedModel(from: signals),
            repo: repo,
            sessionId: sessionId
        )
    }

    private static func resolvedModel(from signals: Signals) -> String {
        resolvedModels(from: signals).first ?? "grok-build"
    }

    private static func resolvedModels(from signals: Signals) -> [String] {
        var out: [String] = []
        func append(_ raw: String?) {
            guard let model = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !model.isEmpty,
                  !out.contains(model)
            else { return }
            out.append(model)
        }
        append(signals.primaryModelId)
        for model in signals.modelsUsed ?? [] {
            append(model)
        }
        return out.isEmpty ? ["grok-build"] : out
    }

    private static func split(_ value: Int, into count: Int) -> [Int] {
        guard count > 0 else { return [] }
        let base = value / count
        let remainder = value % count
        return (0..<count).map { index in
            base + (index < remainder ? 1 : 0)
        }
    }

    private static func dedupKey(sessionId: String, model: String, modelCount: Int) -> String? {
        guard !sessionId.isEmpty else { return nil }
        if modelCount == 1 { return "grok-cli:\(sessionId):signals" }
        return "grok-cli:\(sessionId):signals:\(model)"
    }
}

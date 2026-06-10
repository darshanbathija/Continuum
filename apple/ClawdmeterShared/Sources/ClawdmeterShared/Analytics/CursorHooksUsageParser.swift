import Foundation

/// Parses Cursor IDE hook logs into usage-history records.
///
/// Cursor does not expose a Claude/Codex-style JSONL usage corpus, but the
/// local hook logs include `sessionStart` and `stop` INPUT JSON blocks with
/// workspace roots, model ids, and token totals. This parser treats those
/// stopped generations as real Cursor usage records for analytics/model
/// rollups. The parser emits token-only records; UsageHistoryLoader applies
/// Pricing to those records when the Cursor model resolves to a known rate.
public enum CursorHooksUsageParser {
    public static func defaultLogsDir() -> URL? {
        #if os(macOS)
        return ClawdmeterRealHome.url()
            .appendingPathComponent("Library/Application Support/Cursor/logs", isDirectory: true)
        #else
        return nil
        #endif
    }

    public static func parse(file url: URL) throws -> [UsageRecord] {
        let text = try String(contentsOf: url, encoding: .utf8)
        let decoder = JSONDecoder()
        var records: [UsageRecord] = []
        var modelBySession: [String: String] = [:]
        let fileTimestamp = Self.fileMtime(url) ?? Date(timeIntervalSince1970: 0)

        var searchStart = text.startIndex
        while let marker = text.range(of: "INPUT:", range: searchStart..<text.endIndex) {
            guard let jsonStart = text[marker.upperBound..<text.endIndex].firstIndex(of: "{") else {
                break
            }
            guard let jsonRange = balancedJSONRange(startingAt: jsonStart, in: text) else {
                searchStart = text.index(after: jsonStart)
                continue
            }

            defer { searchStart = jsonRange.upperBound }

            guard let input = try? decoder.decode(HookInput.self, from: Data(text[jsonRange].utf8)) else {
                continue
            }

            if input.hookEventName == "sessionStart" {
                if let model = meaningfulModel(input.model) {
                    for key in input.sessionKeys {
                        modelBySession[key] = model
                    }
                }
                continue
            }

            guard input.hookEventName == "stop", input.hasTokenPayload else {
                continue
            }

            let rawInput = max(0, input.inputTokens ?? 0)
            let cacheRead = max(0, input.cacheReadTokens ?? 0)
            let cacheWrite = max(0, input.cacheWriteTokens ?? 0)
            let regularInput = max(0, rawInput - cacheRead - cacheWrite)
            let output = max(0, input.outputTokens ?? 0)
            let tokens = TokenTotals(
                inputTokens: regularInput,
                outputTokens: output,
                cacheCreationTokens: cacheWrite,
                cacheReadTokens: cacheRead,
                requestCount: 1
            )
            guard tokens.totalTokens > 0 else {
                continue
            }

            let timestamp = timestamp(before: marker.lowerBound, in: text) ?? fileTimestamp
            let model = effectiveModel(for: input, modelBySession: modelBySession)
            let repo = input.workspaceRoots?
                .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                .map { RepoIdentity.normalize($0) }

            records.append(UsageRecord(
                provider: .cursor,
                timestamp: timestamp,
                model: model,
                tokens: tokens,
                repo: repo,
                dedupKey: dedupKey(for: input, fileURL: url, timestamp: timestamp, tokens: tokens)
            ))
        }

        return records
    }

    private struct HookInput: Decodable {
        let conversationId: String?
        let generationId: String?
        let model: String?
        let status: String?
        let inputTokens: Int?
        let outputTokens: Int?
        let cacheReadTokens: Int?
        let cacheWriteTokens: Int?
        let sessionId: String?
        let hookEventName: String?
        let workspaceRoots: [String]?
        let transcriptPath: String?

        enum CodingKeys: String, CodingKey {
            case conversationId = "conversation_id"
            case generationId = "generation_id"
            case model
            case status
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case cacheReadTokens = "cache_read_tokens"
            case cacheWriteTokens = "cache_write_tokens"
            case sessionId = "session_id"
            case hookEventName = "hook_event_name"
            case workspaceRoots = "workspace_roots"
            case transcriptPath = "transcript_path"
        }

        var hasTokenPayload: Bool {
            inputTokens != nil || outputTokens != nil || cacheReadTokens != nil || cacheWriteTokens != nil
        }

        var sessionKeys: [String] {
            [sessionId, conversationId]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
    }

    private static func effectiveModel(for input: HookInput, modelBySession: [String: String]) -> String {
        if let model = meaningfulModel(input.model) {
            return model
        }
        for key in input.sessionKeys {
            if let model = modelBySession[key] {
                return model
            }
        }
        return "cursor-auto"
    }

    private static func meaningfulModel(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        let lower = trimmed.lowercased()
        if lower == "default" || lower == "unknown" || lower == "cursor-default" {
            return nil
        }
        return trimmed
    }

    private static func dedupKey(
        for input: HookInput,
        fileURL: URL,
        timestamp: Date,
        tokens: TokenTotals
    ) -> String {
        let session = input.sessionId ?? input.conversationId ?? input.transcriptPath ?? "unknown-session"
        let generation = input.generationId?.isEmpty == false ? input.generationId! : "unknown-generation"
        let millis = Int(timestamp.timeIntervalSince1970 * 1000)
        return [
            "cursor-hooks",
            fileURL.path,
            session,
            generation,
            String(millis),
            String(tokens.inputTokens),
            String(tokens.outputTokens),
            String(tokens.cacheCreationTokens),
            String(tokens.cacheReadTokens)
        ].joined(separator: ":")
    }

    private static func balancedJSONRange(startingAt start: String.Index, in text: String) -> Range<String.Index>? {
        var index = start
        var depth = 0
        var inString = false
        var escaped = false

        while index < text.endIndex {
            let char = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if char == "\\" {
                    escaped = true
                } else if char == "\"" {
                    inString = false
                }
            } else {
                if char == "\"" {
                    inString = true
                } else if char == "{" {
                    depth += 1
                } else if char == "}" {
                    depth -= 1
                    if depth == 0 {
                        return start..<text.index(after: index)
                    }
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func timestamp(before index: String.Index, in text: String) -> Date? {
        let distance = text.distance(from: text.startIndex, to: index)
        let start = text.index(index, offsetBy: -min(1024, distance), limitedBy: text.startIndex) ?? text.startIndex
        let chunk = String(text[start..<index])
        guard let open = chunk.range(of: "[", options: .backwards),
              let close = chunk[open.upperBound...].firstIndex(of: "]") else {
            return nil
        }

        let raw = String(chunk[open.upperBound..<close])
        // Lock-free fast path first — the per-call formatter allocations
        // here went through ICU on every timestamp (v0.31.17 energy bug).
        if let date = ISO8601Fast.parse(raw) {
            return date
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) {
            return date
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    private static func fileMtime(_ url: URL) -> Date? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return attrs[.modificationDate] as? Date
    }
}

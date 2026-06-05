import Foundation

/// Parses Cursor Agent transcript JSONL files into Cursor usage records.
///
/// Current Cursor Agent transcripts do not persist first-party token counters.
/// They do persist the exact user prompts, assistant text, tool-call payloads,
/// and subagent transcripts. This parser turns that durable transcript corpus
/// into estimated token usage so Cursor's analytics lane reflects real work
/// instead of only Continuum-owned ACP ledger rows.
public enum CursorAgentTranscriptParser {
    public static func defaultProjectsDir() -> URL? {
        #if os(macOS)
        return ClawdmeterRealHome.url()
            .appendingPathComponent(".cursor/projects", isDirectory: true)
        #else
        return nil
        #endif
    }

    public static func isTranscriptFile(_ url: URL) -> Bool {
        url.path.contains("/agent-transcripts/")
            && url.lastPathComponent.hasSuffix(".jsonl")
    }

    public static func parse(file url: URL) throws -> [UsageRecord] {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            return []
        }

        let repo = inferRepo(from: text)
        let timestamp = fileMtime(url) ?? Date(timeIntervalSince1970: 0)
        let sessionId = url.deletingPathExtension().lastPathComponent
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)

        var records: [UsageRecord] = []
        for (offset, rawLine) in lines.enumerated() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(rawLine)) as? [String: Any] else {
                continue
            }
            let role = (object["role"] as? String)?.lowercased() ?? ""
            guard let message = object["message"] else { continue }

            let model = meaningfulModel(modelName(in: message)) ?? "composer-2.5-fast"
            let charCount = max(0, estimatedCharacters(in: message))
            guard charCount > 0 else { continue }

            let estimatedTokens = max(1, (charCount + 3) / 4)
            let tokens: TokenTotals
            switch role {
            case "user":
                tokens = TokenTotals(inputTokens: estimatedTokens, requestCount: 1)
            case "assistant":
                tokens = TokenTotals(outputTokens: estimatedTokens, requestCount: 1)
            default:
                continue
            }

            records.append(UsageRecord(
                provider: .cursor,
                timestamp: timestamp,
                model: model,
                tokens: tokens,
                repo: repo,
                dedupKey: [
                    "cursor-agent-transcript",
                    sessionId,
                    String(offset),
                    role
                ].joined(separator: ":")
            ))
        }
        return records
    }

    private static func estimatedCharacters(in value: Any) -> Int {
        if let string = value as? String {
            return string.count
        }
        if let array = value as? [Any] {
            return array.reduce(0) { $0 + estimatedCharacters(in: $1) }
        }
        guard let dict = value as? [String: Any] else {
            return 0
        }

        if let content = dict["content"] {
            return estimatedCharacters(in: content)
        }

        let type = dict["type"] as? String
        if type == "text", let text = dict["text"] as? String {
            return text.count
        }
        if type == "redacted-reasoning", let data = dict["data"] as? String {
            return data.count
        }
        if type == "tool_use" {
            var count = (dict["name"] as? String)?.count ?? 0
            if let input = dict["input"] {
                count += compactJSONLength(input)
            }
            return count
        }
        return 0
    }

    private static func modelName(in value: Any) -> String? {
        if let array = value as? [Any] {
            for item in array {
                if let model = modelName(in: item) {
                    return model
                }
            }
            return nil
        }
        guard let dict = value as? [String: Any] else {
            return nil
        }
        if let providerOptions = dict["providerOptions"] as? [String: Any],
           let cursor = providerOptions["cursor"] as? [String: Any],
           let model = cursor["modelName"] as? String {
            return model
        }
        if let input = dict["input"] as? [String: Any],
           let model = input["model"] as? String {
            return model
        }
        if let content = dict["content"] {
            return modelName(in: content)
        }
        return nil
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

    private static func compactJSONLength(_ value: Any) -> Int {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
            return 0
        }
        return data.count
    }

    private static func inferRepo(from text: String) -> String? {
        let markers = [
            "Workspace Path:",
            "Workspace:",
            "workspace:",
            "Workspace path:"
        ]
        for marker in markers {
            if let marked = firstPath(after: marker, in: text),
               let repo = normalizeExistingRepo(marked) {
                return repo
            }
        }
        for candidate in allUserPaths(in: text) {
            if let repo = normalizeExistingRepo(candidate) {
                return repo
            }
        }
        return nil
    }

    private static func firstPath(after marker: String, in text: String) -> String? {
        guard let range = text.range(of: marker) else { return nil }
        let tail = text[range.upperBound...]
        guard let start = tail.firstIndex(of: "/") else { return nil }
        return pathStarting(at: start, in: text)
    }

    private static func allUserPaths(in text: String) -> [String] {
        var paths: [String] = []
        var searchStart = text.startIndex
        while let range = text.range(of: "/Users/", range: searchStart..<text.endIndex) {
            if let path = pathStarting(at: range.lowerBound, in: text) {
                paths.append(path)
            }
            searchStart = range.upperBound
        }
        return paths
    }

    private static func pathStarting(at start: String.Index, in text: String) -> String? {
        var end = start
        let delimiters = CharacterSet(charactersIn: "\"'\n\r\t`<>\\")
        while end < text.endIndex {
            let scalarView = String(text[end]).unicodeScalars
            if scalarView.contains(where: { delimiters.contains($0) }) {
                break
            }
            end = text.index(after: end)
        }
        let raw = String(text[start..<end])
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:)[]{}"))
        return raw.isEmpty ? nil : raw
    }

    private static func normalizeExistingRepo(_ path: String) -> String? {
        var url = URL(fileURLWithPath: path).standardizedFileURL
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue {
            url.deleteLastPathComponent()
        }
        while url.path != "/" {
            if fm.fileExists(atPath: url.appendingPathComponent(".git", isDirectory: true).path) {
                return RepoIdentity.normalize(url.path)
            }
            url.deleteLastPathComponent()
        }
        return nil
    }

    private static func fileMtime(_ url: URL) -> Date? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return attrs[.modificationDate] as? Date
    }
}

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

    public static func parse(file url: URL, modelHints: [String: String] = [:]) throws -> [UsageRecord] {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            return []
        }

        let repo = inferRepo(from: text)
        let timestamp = fileMtime(url) ?? Date(timeIntervalSince1970: 0)
        let sessionId = url.deletingPathExtension().lastPathComponent
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        let sessionModelHint = firstUserPromptFingerprint(in: lines)
            .flatMap { modelHints[$0] }

        var records: [UsageRecord] = []
        var accumulatedContextCharacters = 0
        for (offset, rawLine) in lines.enumerated() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(rawLine)) as? [String: Any] else {
                continue
            }
            let role = (object["role"] as? String)?.lowercased() ?? ""
            guard let message = object["message"] else { continue }

            let model = meaningfulModel(providerModelName(in: message)) ?? sessionModelHint ?? "composer-2.5-fast"
            let charCount = max(0, estimatedCharacters(in: message))
            switch role {
            case "user":
                accumulatedContextCharacters += charCount
            case "assistant":
                let inputTokens = accumulatedContextCharacters > 0 ? max(1, (accumulatedContextCharacters + 3) / 4) : 0
                let outputTokens = charCount > 0 ? max(1, (charCount + 3) / 4) : 0
                guard inputTokens > 0 || outputTokens > 0 else { continue }
                let tokens = TokenTotals(
                    inputTokens: inputTokens,
                    outputTokens: outputTokens,
                    requestCount: 1
                )
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
                accumulatedContextCharacters += charCount
            default:
                accumulatedContextCharacters += charCount
            }
        }
        return records
    }

    public static func taskModelHints(file url: URL) throws -> [String: String] {
        let data = try Data(contentsOf: url)
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        var hints: [String: String] = [:]
        for rawLine in lines {
            guard let object = try? JSONSerialization.jsonObject(with: Data(rawLine)) as? [String: Any],
                  let message = object["message"] else {
                continue
            }
            collectTaskModelHints(in: message, into: &hints)
        }
        return hints
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
        if let result = dict["result"] {
            return estimatedCharacters(in: result)
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

    private static func textForInference(in value: Any) -> String {
        if let string = value as? String {
            return string
        }
        if let array = value as? [Any] {
            return array.map { textForInference(in: $0) }.joined(separator: "\n")
        }
        guard let dict = value as? [String: Any] else {
            return ""
        }
        var parts: [String] = []
        if let text = dict["text"] as? String {
            parts.append(text)
        }
        if let content = dict["content"] {
            parts.append(textForInference(in: content))
        }
        if let result = dict["result"] {
            parts.append(textForInference(in: result))
        }
        if let input = dict["input"], let rendered = compactJSONString(input) {
            parts.append(rendered)
        }
        return parts.joined(separator: "\n")
    }

    private static func providerModelName(in value: Any) -> String? {
        if let array = value as? [Any] {
            for item in array {
                if let model = providerModelName(in: item) {
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
        if let model = dict["model"] as? String { return model }
        if let model = dict["modelName"] as? String { return model }
        if let content = dict["content"] {
            return providerModelName(in: content)
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
        compactJSONString(value)?.utf8.count ?? 0
    }

    private static func compactJSONString(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func firstUserPromptFingerprint(in lines: [Data.SubSequence]) -> String? {
        for rawLine in lines {
            guard let object = try? JSONSerialization.jsonObject(with: Data(rawLine)) as? [String: Any],
                  (object["role"] as? String)?.lowercased() == "user",
                  let message = object["message"] else {
                continue
            }
            return promptFingerprint(textForInference(in: message))
        }
        return nil
    }

    private static func collectTaskModelHints(in value: Any, into hints: inout [String: String]) {
        if let array = value as? [Any] {
            for item in array {
                collectTaskModelHints(in: item, into: &hints)
            }
            return
        }
        guard let dict = value as? [String: Any] else {
            return
        }
        if (dict["name"] as? String) == "Task",
           let input = dict["input"] as? [String: Any],
           let model = meaningfulModel(input["model"] as? String),
           let prompt = input["prompt"] as? String,
           let fingerprint = promptFingerprint(prompt) {
            hints[fingerprint] = model
        }
        for value in dict.values {
            collectTaskModelHints(in: value, into: &hints)
        }
    }

    static func promptFingerprint(_ raw: String) -> String? {
        var text = raw
        if let userQuery = contentsBetween("<user_query>", and: "</user_query>", in: text) {
            text = userQuery
        }
        text = removingBlocks(start: "<timestamp>", end: "</timestamp>", from: text)
        let normalized = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !normalized.isEmpty else {
            return nil
        }
        return normalized
    }

    private static func contentsBetween(_ startMarker: String, and endMarker: String, in text: String) -> String? {
        guard let startRange = text.range(of: startMarker),
              let endRange = text.range(of: endMarker, range: startRange.upperBound..<text.endIndex) else {
            return nil
        }
        return String(text[startRange.upperBound..<endRange.lowerBound])
    }

    private static func removingBlocks(start startMarker: String, end endMarker: String, from text: String) -> String {
        var output = text
        while let startRange = output.range(of: startMarker),
              let endRange = output.range(of: endMarker, range: startRange.upperBound..<output.endIndex) {
            output.removeSubrange(startRange.lowerBound..<endRange.upperBound)
        }
        return output
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

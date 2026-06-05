#if os(macOS)
import Foundation
import SQLite3

/// Parses Cursor's global `agentKv:blob:*` cache rows into estimated usage.
///
/// Cursor Agent transcripts are intentionally compact and often omit the large
/// context blobs sent to the model. The global Cursor state DB keeps many of
/// those blobs under `cursorDiskKV`, keyed by content hash. It still does not
/// expose first-party token counters, so this parser estimates tokens from the
/// persisted input/output text and lets `Pricing` attach known model rates.
public enum CursorAgentKVUsageParser {
    public static func defaultStateDatabaseURL() -> URL? {
        ClawdmeterRealHome.url()
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    public static func parse(databaseURL url: URL) -> [UsageRecord] {
        var db: OpaquePointer?
        let uri = "file:\(url.path)?mode=ro&immutable=0"
        let rc = sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil)
        guard rc == SQLITE_OK, let db else {
            if let db { sqlite3_close_v2(db) }
            return []
        }
        defer { sqlite3_close_v2(db) }
        sqlite3_busy_timeout(db, 250)

        let sql = "SELECT key, value FROM cursorDiskKV WHERE key LIKE 'agentKv:blob:%'"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            if let stmt { sqlite3_finalize(stmt) }
            return []
        }
        defer { sqlite3_finalize(stmt) }

        let fallbackTimestamp = sqliteMtime(url) ?? Date(timeIntervalSince1970: 0)
        var records: [UsageRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let keyPtr = sqlite3_column_text(stmt, 0),
                  sqlite3_column_type(stmt, 1) == SQLITE_BLOB else {
                continue
            }
            let key = String(cString: keyPtr)
            let length = Int(sqlite3_column_bytes(stmt, 1))
            guard length > 0, let pointer = sqlite3_column_blob(stmt, 1) else {
                continue
            }
            let data = Data(bytes: pointer, count: length)
            if let record = parseBlob(key: key, data: data, fallbackTimestamp: fallbackTimestamp) {
                records.append(record)
            }
        }
        return records
    }

    public static func parseBlob(key: String, data: Data, fallbackTimestamp: Date) -> UsageRecord? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              hasCursorProviderOptions(object),
              let role = (object["role"] as? String)?.lowercased(),
              let content = object["content"] else {
            return nil
        }

        let charCount = estimatedCharacters(in: content)
        guard charCount > 0 else { return nil }
        let estimatedTokens = max(1, (charCount + 3) / 4)
        let tokens: TokenTotals
        switch role {
        case "user", "system", "tool":
            tokens = TokenTotals(inputTokens: estimatedTokens, requestCount: 1)
        case "assistant":
            tokens = TokenTotals(outputTokens: estimatedTokens, requestCount: 1)
        default:
            return nil
        }

        let text = textForInference(in: content)
        let timestamp = embeddedDate(in: text) ?? fallbackTimestamp
        let repo = inferRepo(from: text)
        let model = meaningfulModel(modelName(in: object)) ?? "composer-2.5-fast"

        return UsageRecord(
            provider: .cursor,
            timestamp: timestamp,
            model: model,
            tokens: tokens,
            repo: repo,
            dedupKey: "cursor-agent-kv:\(key):\(role)"
        )
    }

    private static func hasCursorProviderOptions(_ object: [String: Any]) -> Bool {
        guard let providerOptions = object["providerOptions"] as? [String: Any] else {
            return false
        }
        return providerOptions["cursor"] != nil
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
        if let text = dict["text"] as? String {
            return text.count
        }
        if let result = dict["result"] {
            return estimatedCharacters(in: result)
        }
        if let input = dict["input"] {
            return compactJSONLength(input)
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
        if let model = dict["model"] as? String {
            return model
        }
        if let input = dict["input"] {
            return modelName(in: input)
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
        compactJSONString(value)?.utf8.count ?? 0
    }

    private static func compactJSONString(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func embeddedDate(in text: String) -> Date? {
        guard let range = text.range(of: "Today's date:") else {
            return nil
        }
        let tail = text[range.upperBound...]
        let line = tail.prefix { char in
            char != "\n" && char != "\r" && char != "<"
        }
        let raw = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        for format in ["EEEE MMM d, yyyy", "EEEE MMMM d, yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) {
                return Calendar.current.startOfDay(for: date)
            }
        }
        return nil
    }

    private static func inferRepo(from text: String) -> String? {
        for marker in ["Workspace Path:", "Workspace:", "workspace:", "Workspace path:"] {
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

    private static func sqliteMtime(_ url: URL) -> Date? {
        var dates: [Date] = []
        for path in [url.path, url.path + "-wal", url.path + "-shm"] {
            let fileURL = URL(fileURLWithPath: path)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
               let date = attrs[.modificationDate] as? Date {
                dates.append(date)
            }
        }
        return dates.max()
    }
}
#endif

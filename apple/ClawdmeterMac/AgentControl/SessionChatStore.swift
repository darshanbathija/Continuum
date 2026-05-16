import Foundation
import ClawdmeterShared
import OSLog

private let chatLogger = Logger(subsystem: "com.clawdmeter.mac", category: "ChatStore")

/// Per-session chat-style event store. Tails the session's JSONL, parses
/// each line into a typed `ChatMessage`, and publishes the array for the
/// SwiftUI chat view to render.
///
/// What we parse (Claude Code JSONL shape):
/// - `type=user`: a `message.content` string OR an array containing
///   `tool_result` blocks (for tool returns) and/or `text` blocks.
/// - `type=assistant`: `message.content` is an array of `text` /
///   `tool_use` blocks. `tool_use` carries `name`+`input`.
/// - `type=attachment` / `type=queue-operation` / `type=last-prompt`:
///   skipped (not user-visible chat).
///
/// The store accumulates messages in arrival order. Live updates via the
/// JSONLTail's DispatchSource fire `applyLine` on the main actor so the
/// SwiftUI view re-renders incrementally.
@MainActor
public final class SessionChatStore: ObservableObject {

    public struct ChatMessage: Identifiable, Hashable, Sendable {
        public enum Kind: String, Hashable, Sendable {
            case userText
            case assistantText
            case toolCall
            case toolResult
            case meta  // sidecar info like "Session started", "Plan ready"
        }
        public let id: String
        public let kind: Kind
        public let title: String   // tool name, "You", "Claude", etc
        public let body: String
        /// Auxiliary detail for tool calls / results — args summary, exit code,
        /// stdout/stderr preview. Optional second-line under the main body.
        public let detail: String?
        public let at: Date
        /// Whether a tool_result reported `is_error: true`. Tints the row red.
        public let isError: Bool

        public init(
            id: String,
            kind: Kind,
            title: String,
            body: String,
            detail: String? = nil,
            at: Date,
            isError: Bool = false
        ) {
            self.id = id
            self.kind = kind
            self.title = title
            self.body = body
            self.detail = detail
            self.at = at
            self.isError = isError
        }
    }

    @Published public private(set) var messages: [ChatMessage] = []
    @Published public private(set) var isLoading: Bool = true
    @Published public private(set) var lastError: String?

    public let sessionId: UUID
    private let sessionFileURL: URL
    private var tail: JSONLTail?
    /// Dedupe key for tool_use blocks so we don't double-show them when we
    /// also see a corresponding tool_result.
    private var seenIds: Set<String> = []

    public init(sessionId: UUID, sessionFileURL: URL) {
        self.sessionId = sessionId
        self.sessionFileURL = sessionFileURL
    }

    public func start() {
        guard tail == nil else { return }
        chatLogger.info("Starting chat store for session \(self.sessionId.uuidString, privacy: .public) at \(self.sessionFileURL.path, privacy: .public)")
        let tail = JSONLTail(fileURL: sessionFileURL) { [weak self] json in
            // JSONLTail's handler runs on its own queue. Hop to main.
            Task { @MainActor in
                self?.applyLine(json)
            }
        }
        self.tail = tail
        tail.start()
        // Mark loading false after a brief settle window.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            self.isLoading = false
        }
    }

    public func stop() {
        tail?.stop()
        tail = nil
    }

    // MARK: - Parsing

    private func applyLine(_ json: [String: Any]) {
        let type = json["type"] as? String ?? ""
        let at = Self.parseTimestamp(json) ?? Date()
        switch type {
        case "user":
            handleUser(json, at: at)
        case "assistant":
            handleAssistant(json, at: at)
        default:
            // skip queue-operation / last-prompt / attachment / etc
            break
        }
    }

    private func handleUser(_ json: [String: Any], at: Date) {
        guard let message = json["message"] as? [String: Any] else { return }
        // user content can be a string OR an array of blocks (with tool_results).
        if let s = message["content"] as? String, !s.isEmpty {
            append(ChatMessage(
                id: stableId(json, suffix: "user-text"),
                kind: .userText,
                title: "You",
                body: s,
                at: at
            ))
            return
        }
        if let blocks = message["content"] as? [[String: Any]] {
            for (i, block) in blocks.enumerated() {
                let blockType = block["type"] as? String ?? ""
                let baseId = stableId(json, suffix: "u\(i)-\(blockType)")
                switch blockType {
                case "text":
                    if let s = block["text"] as? String, !s.isEmpty {
                        append(ChatMessage(
                            id: baseId, kind: .userText,
                            title: "You", body: s, at: at
                        ))
                    }
                case "tool_result":
                    let resultId = (block["tool_use_id"] as? String) ?? baseId
                    let isError = (block["is_error"] as? Bool) ?? false
                    let body = Self.flattenContent(block["content"])
                    append(ChatMessage(
                        id: "result:\(resultId)",
                        kind: .toolResult,
                        title: "Tool result",
                        body: body,
                        at: at,
                        isError: isError
                    ))
                default:
                    break
                }
            }
        }
    }

    private func handleAssistant(_ json: [String: Any], at: Date) {
        guard let message = json["message"] as? [String: Any] else { return }
        guard let blocks = message["content"] as? [[String: Any]] else {
            // Some streams put plain text directly on `content`.
            if let s = message["content"] as? String, !s.isEmpty {
                append(ChatMessage(
                    id: stableId(json, suffix: "a-text"),
                    kind: .assistantText,
                    title: "Claude",
                    body: s,
                    at: at
                ))
            }
            return
        }
        for (i, block) in blocks.enumerated() {
            let blockType = block["type"] as? String ?? ""
            let baseId = stableId(json, suffix: "a\(i)-\(blockType)")
            switch blockType {
            case "text":
                if let s = block["text"] as? String, !s.isEmpty {
                    append(ChatMessage(
                        id: baseId, kind: .assistantText,
                        title: "Claude", body: s, at: at
                    ))
                }
            case "tool_use":
                let toolUseId = (block["id"] as? String) ?? baseId
                let name = (block["name"] as? String) ?? "tool"
                let inputSummary = Self.summarizeInput(block["input"], for: name)
                append(ChatMessage(
                    id: "call:\(toolUseId)",
                    kind: .toolCall,
                    title: name,
                    body: inputSummary,
                    detail: nil,
                    at: at
                ))
            default:
                break
            }
        }
    }

    private func append(_ message: ChatMessage) {
        // De-dupe on id (re-tailed files may replay).
        if seenIds.contains(message.id) { return }
        seenIds.insert(message.id)
        messages.append(message)
    }

    // MARK: - Helpers

    private func stableId(_ json: [String: Any], suffix: String) -> String {
        let uuid = (json["uuid"] as? String) ?? (json["timestamp"] as? String) ?? UUID().uuidString
        return "\(uuid):\(suffix)"
    }

    /// Compact one-line summary of a tool_use `input` for the row body.
    static func summarizeInput(_ input: Any?, for tool: String) -> String {
        guard let dict = input as? [String: Any] else { return "" }
        switch tool {
        case "Bash":
            if let cmd = dict["command"] as? String {
                return cmd.replacingOccurrences(of: "\n", with: " ")
            }
        case "Read":
            if let path = dict["file_path"] as? String { return path }
        case "Write", "Edit":
            if let path = dict["file_path"] as? String { return path }
        case "Glob", "Grep":
            if let pattern = dict["pattern"] as? String { return pattern }
        case "WebFetch":
            if let url = dict["url"] as? String { return url }
        case "WebSearch":
            if let q = dict["query"] as? String { return q }
        case "Task":
            if let desc = dict["description"] as? String { return desc }
        default:
            break
        }
        // Fallback: shortest non-empty string field.
        let stringFields = dict.compactMap { (_, v) -> String? in
            if let s = v as? String, !s.isEmpty { return s }
            return nil
        }
        return stringFields.min(by: { $0.count < $1.count }) ?? ""
    }

    /// tool_result `content` may be a string OR array of blocks. Flatten to
    /// a single string, joining text blocks with newlines, capped at 4KB
    /// for the chat row (the user can expand via UI later).
    static func flattenContent(_ content: Any?) -> String {
        if let s = content as? String { return String(s.prefix(4096)) }
        if let blocks = content as? [[String: Any]] {
            let strs = blocks.compactMap { block -> String? in
                if block["type"] as? String == "text" {
                    return block["text"] as? String
                }
                return nil
            }
            let joined = strs.joined(separator: "\n")
            return String(joined.prefix(4096))
        }
        return ""
    }

    static func parseTimestamp(_ json: [String: Any]) -> Date? {
        if let s = json["timestamp"] as? String {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: s) { return d }
            let g = ISO8601DateFormatter()
            return g.date(from: s)
        }
        return nil
    }

    /// Resolve the JSONL file for a session. Claude encodes the cwd as
    /// `~/.claude/projects/<encoded>/<session-id>.jsonl`. We don't know the
    /// session-id (Claude's own UUID); we pick the newest .jsonl in the
    /// project dir as a best-effort match.
    public static func resolveSessionFileURL(repoCwd: String) -> URL? {
        let encoded = repoCwd.replacingOccurrences(of: "/", with: "-")
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects/\(encoded)")
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return nil }
        let jsonls = contents.filter { $0.pathExtension == "jsonl" }
        return jsonls.max { a, b in
            let ad = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let bd = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return ad < bd
        }
    }
}

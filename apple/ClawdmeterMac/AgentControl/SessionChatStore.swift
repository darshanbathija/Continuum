import Foundation
import ClawdmeterShared
import OSLog
import os.signpost

private let chatLogger = Logger(subsystem: "com.clawdmeter.mac", category: "ChatStore")

/// Perf-overhaul P0/T14 instrumentation. Always-on; OSSignposts are free
/// at runtime when no Instruments trace is attached. Captures the
/// session-open → first-paint window so we can prove the perf wins in
/// future refactors.
let chatPerfLog = OSLog(subsystem: "com.clawdmeter.mac", category: "Performance")

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

    /// `ChatMessage` is now the Shared value type (T1 extraction). Keeping
    /// the SessionChatStore.ChatMessage alias preserves the existing
    /// `[SessionChatStore.ChatMessage]` API used by PRMirror and views.
    public typealias ChatMessage = ClawdmeterShared.ChatMessage

    /// Snapshot of all derived chat state — items array (with ToolPair
    /// runs), plus future per-pane caches added in T8/T9. Published as
    /// a single value so SwiftUI's Combine fan-out is one invalidation
    /// per frame instead of N per message. Codex tension #4 baked in:
    /// consistency by construction.
    public struct ChatSnapshot: Sendable, Equatable {
        public let items: [ChatItem]
        /// Monotonic counter that bumps each time the snapshot updates.
        /// View code uses this for `.onChange` triggers instead of
        /// `items.last?.id`, which would change object identity per render.
        public let updateCounter: UInt64

        public static let empty = ChatSnapshot(items: [], updateCounter: 0)
    }

    @Published public private(set) var snapshot: ChatSnapshot = .empty
    /// Back-compat: views that still call `store.messages` keep working.
    /// Derived from `snapshot.items`; populated on each snapshot commit.
    /// Removed in T5 once all view code reads `snapshot.items` directly.
    @Published public private(set) var messages: [ChatMessage] = []
    @Published public private(set) var isLoading: Bool = true
    @Published public private(set) var lastError: String?

    public let sessionId: UUID
    private let sessionFileURL: URL
    private var tail: JSONLTail?
    /// Background parser actor — owns ChatItemBuilder, ingests typed
    /// `ParsedLine` values, never touches main. The 16ms commit task
    /// polls `await staging.snapshot()` and publishes to main.
    private let staging = StagingParser()
    /// Generation token (codex tension #6). Bumped on every `start()` /
    /// `stop()`. Background commit task captures its generation at launch
    /// and silently drops any commit where the captured generation
    /// doesn't match the current — so stale parses from an evicted
    /// store can't publish after navigation.
    private var parseGeneration: UInt64 = 0
    private var commitTask: Task<Void, Never>?

    public init(sessionId: UUID, sessionFileURL: URL) {
        self.sessionId = sessionId
        self.sessionFileURL = sessionFileURL
    }

    public func start() {
        guard tail == nil else { return }
        parseGeneration &+= 1
        let generation = parseGeneration
        let signpostID = OSSignpostID(log: chatPerfLog, object: self)
        os_signpost(.begin, log: chatPerfLog, name: "session-open",
                    signpostID: signpostID,
                    "session=%{public}@", self.sessionId.uuidString)
        startSignpostID = signpostID
        chatLogger.info("Starting chat store for session \(self.sessionId.uuidString, privacy: .public) at \(self.sessionFileURL.path, privacy: .public)")

        // JSONLTail still runs on its background queue. The handler
        // converts [String: Any] → typed `ParsedLine` (Sendable) BEFORE
        // crossing into the actor — codex tension #7b: typed boundary,
        // not raw dictionaries.
        let staging = self.staging
        let tail = JSONLTail(fileURL: sessionFileURL) { json in
            guard let parsed = ParsedLine.from(json: json) else { return }
            Task { await staging.ingest(parsed) }
        }
        self.tail = tail
        tail.start()

        // Background commit task: every 16ms, snapshot the staging actor
        // and publish to main. Generation-token guard suppresses any
        // commits from stale parses (codex tension #6).
        commitTask = Task.detached(priority: .userInitiated) { [weak self] in
            // Single signposted batch loop. Each iteration is one frame's
            // worth of commit work — cheap when nothing changed, real
            // work only when items array grew.
            var lastCommittedCounter: UInt64 = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 16_000_000)
                let next = await staging.snapshot()
                guard next.updateCounter != lastCommittedCounter else { continue }
                lastCommittedCounter = next.updateCounter
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    guard self.parseGeneration == generation else { return }
                    self.snapshot = next
                    // Back-compat: rebuild `messages` array from the
                    // snapshot's items. Drops in T5 once views read
                    // snapshot.items directly.
                    self.messages = Self.flattenMessages(from: next.items)
                }
            }
        }

        // Mark loading false after a settle window.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard self.parseGeneration == generation else { return }
            self.isLoading = false
            if let id = self.startSignpostID {
                os_signpost(.end, log: chatPerfLog, name: "session-open",
                            signpostID: id,
                            "messageCount=%d", self.messages.count)
                self.startSignpostID = nil
            }
        }
    }

    private var startSignpostID: OSSignpostID?

    public func stop() {
        // Bump generation so any in-flight commit task drops its next
        // publish (defense-in-depth with Task cancellation).
        parseGeneration &+= 1
        commitTask?.cancel()
        commitTask = nil
        tail?.stop()
        tail = nil
    }

    /// Flatten `ChatItem.toolRun` pairs back into a flat message array.
    /// Order matches arrival order — useful for back-compat views and
    /// for `PRMirror.findPRURL` which scans every assistant body / tool
    /// result for a github.com PR URL.
    private static func flattenMessages(from items: [ChatItem]) -> [ChatMessage] {
        var out: [ChatMessage] = []
        for item in items {
            switch item {
            case .message(let m):
                out.append(m)
            case .toolRun(_, let pairs):
                for pair in pairs {
                    out.append(pair.call)
                    if let r = pair.result { out.append(r) }
                }
            }
        }
        return out
    }

    // MARK: - Parsing
    // The legacy main-actor `applyLine` + `handleUser` / `handleAssistant`
    // path was replaced by the off-main `ParsedLine.from(json:)` →
    // `StagingParser.ingest(_:)` pipeline. Helpers below
    // (`summarizeInput`, `expandedDetail`, `flattenContent`,
    // `parseTimestamp`) are marked `nonisolated` so ParsedLine.from can
    // call them from any context.


    // MARK: - Helpers (used by ParsedLine.from)

    /// Generate a stable id from a JSON line's uuid/timestamp field.
    nonisolated static func stableId(_ json: [String: Any], suffix: String) -> String {
        let uuid = (json["uuid"] as? String) ?? (json["timestamp"] as? String) ?? UUID().uuidString
        return "\(uuid):\(suffix)"
    }

    /// Compact one-line summary of a tool_use `input` for the row label. This
    /// is what the user sees in the collapsed disclosure header — favors a
    /// human-readable description over the raw command bytes.
    nonisolated static func summarizeInput(_ input: Any?, for tool: String) -> String {
        guard let dict = input as? [String: Any] else { return "" }
        switch tool {
        case "Bash":
            // Claude Code passes a one-liner `description` alongside the
            // command; use that as the headline so "Ran Stop the old build"
            // reads better than "Ran kill 3487 2>&1 …".
            if let desc = (dict["description"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !desc.isEmpty {
                return desc
            }
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

    /// Verbose detail shown only when the user expands the tool row. For
    /// Bash this is the full command (multi-line preserved); for file ops
    /// `nil` — the path in the headline is already the full detail.
    nonisolated static func expandedDetail(_ input: Any?, for tool: String) -> String? {
        guard let dict = input as? [String: Any] else { return nil }
        switch tool {
        case "Bash":
            return dict["command"] as? String
        case "Grep":
            // Pattern is the headline; surface the optional path/include
            // glob in the detail so the row can show full scope on expand.
            var bits: [String] = []
            if let path = dict["path"] as? String, !path.isEmpty { bits.append("path: \(path)") }
            if let include = dict["include"] as? String, !include.isEmpty { bits.append("include: \(include)") }
            return bits.isEmpty ? nil : bits.joined(separator: "\n")
        case "Task":
            return dict["prompt"] as? String
        case "WebFetch":
            return dict["prompt"] as? String
        default:
            return nil
        }
    }

    /// tool_result `content` may be a string OR array of blocks. Flatten to
    /// a single string, joining text blocks with newlines, capped at 4KB
    /// for the chat row (the user can expand via UI later).
    nonisolated static func flattenContent(_ content: Any?) -> String {
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

    nonisolated static func parseTimestamp(_ json: [String: Any]) -> Date? {
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
    /// `~/.claude/projects/<encoded>/<session-id>.jsonl`, replacing `/`,
    /// `_`, AND ` ` (and arguably more) with `-`. The naive `/`→`-` we used
    /// pre-G2 silently missed any cwd containing underscores or spaces —
    /// the very case in this repo (`/Users/darshanbathija_1/Downloads/CC Watch/...`).
    ///
    /// We also walk up parent directories: when Claude was launched from a
    /// parent of the git repo (e.g. `CC Watch/` instead of `CC Watch/Clawdmeter/`),
    /// the JSONLs are filed under the parent's encoded name. `RepoIdentity.normalize`
    /// has already descended us into the git child, but the project dir is
    /// for the parent. Walking up catches it.
    public static func resolveSessionFileURL(repoCwd: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let projects = home.appendingPathComponent(".claude/projects")
        var current = (repoCwd as NSString).standardizingPath
        while !current.isEmpty, current != "/" {
            if let url = newestJSONL(in: projects, claudeEncoded: encodeCwd(current)) {
                return url
            }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current { break }
            current = parent
        }
        return nil
    }

    /// Claude's project-dir name encoding. `/`, `_`, and ` ` all collapse
    /// to `-`. Letter case is preserved.
    static func encodeCwd(_ cwd: String) -> String {
        cwd
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")
    }

    private static func newestJSONL(in projects: URL, claudeEncoded: String) -> URL? {
        let dir = projects.appendingPathComponent(claudeEncoded)
        guard FileManager.default.fileExists(atPath: dir.path) else { return nil }
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

// MARK: - ParsedLine (typed Sendable boundary)

/// Typed representation of one JSONL line. Converted from `[String: Any]`
/// on the JSONLTail's dispatch queue (off main + off actor), then crossed
/// into the StagingParser actor as a `Sendable` value. Closes the codex
/// tension #7b trap: `[String: Any]` is not properly Sendable.
struct ParsedLine: Sendable {
    let timestamp: Date
    let messages: [ChatMessage]

    /// Convert a raw JSONL dict into a typed ParsedLine. Returns `nil` for
    /// lines we don't surface (queue-operation, last-prompt, attachment,
    /// etc.) or malformed lines. Pure value transform.
    static func from(json: [String: Any]) -> ParsedLine? {
        let at = SessionChatStore.parseTimestamp(json) ?? Date()
        let type = json["type"] as? String ?? ""
        switch type {
        case "user":
            return decodeUser(json: json, at: at)
        case "assistant":
            return decodeAssistant(json: json, at: at)
        default:
            return nil
        }
    }

    private static func decodeUser(json: [String: Any], at: Date) -> ParsedLine? {
        guard let message = json["message"] as? [String: Any] else { return nil }
        var out: [ChatMessage] = []
        if let s = message["content"] as? String, !s.isEmpty {
            out.append(ChatMessage(
                id: SessionChatStore.stableId(json, suffix: "user-text"),
                kind: .userText, title: "You", body: s, at: at
            ))
        } else if let blocks = message["content"] as? [[String: Any]] {
            for (i, block) in blocks.enumerated() {
                let blockType = block["type"] as? String ?? ""
                let baseId = SessionChatStore.stableId(json, suffix: "u\(i)-\(blockType)")
                switch blockType {
                case "text":
                    if let s = block["text"] as? String, !s.isEmpty {
                        out.append(ChatMessage(
                            id: baseId, kind: .userText, title: "You",
                            body: s, at: at
                        ))
                    }
                case "tool_result":
                    let resultId = (block["tool_use_id"] as? String) ?? baseId
                    let isError = (block["is_error"] as? Bool) ?? false
                    let body = SessionChatStore.flattenContent(block["content"])
                    out.append(ChatMessage(
                        id: "result:\(resultId)", kind: .toolResult,
                        title: "Tool result", body: body, at: at,
                        isError: isError
                    ))
                default:
                    break
                }
            }
        }
        guard !out.isEmpty else { return nil }
        return ParsedLine(timestamp: at, messages: out)
    }

    private static func decodeAssistant(json: [String: Any], at: Date) -> ParsedLine? {
        guard let message = json["message"] as? [String: Any] else { return nil }
        var out: [ChatMessage] = []
        if let s = message["content"] as? String, !s.isEmpty {
            out.append(ChatMessage(
                id: SessionChatStore.stableId(json, suffix: "a-text"),
                kind: .assistantText, title: "Claude", body: s, at: at
            ))
        } else if let blocks = message["content"] as? [[String: Any]] {
            for (i, block) in blocks.enumerated() {
                let blockType = block["type"] as? String ?? ""
                let baseId = SessionChatStore.stableId(json, suffix: "a\(i)-\(blockType)")
                switch blockType {
                case "text":
                    if let s = block["text"] as? String, !s.isEmpty {
                        out.append(ChatMessage(
                            id: baseId, kind: .assistantText, title: "Claude",
                            body: s, at: at
                        ))
                    }
                case "tool_use":
                    let toolUseId = (block["id"] as? String) ?? baseId
                    let name = (block["name"] as? String) ?? "tool"
                    let inputSummary = SessionChatStore.summarizeInput(
                        block["input"], for: name
                    )
                    let inputDetail = SessionChatStore.expandedDetail(
                        block["input"], for: name
                    )
                    out.append(ChatMessage(
                        id: "call:\(toolUseId)", kind: .toolCall, title: name,
                        body: inputSummary, detail: inputDetail, at: at
                    ))
                default:
                    break
                }
            }
        }
        guard !out.isEmpty else { return nil }
        return ParsedLine(timestamp: at, messages: out)
    }
}

// MARK: - StagingParser (background actor)

/// Owns the `ChatItemBuilder` + dedup state. Consumes typed `ParsedLine`
/// values from off-main contexts (JSONLTail's dispatch queue → ParsedLine
/// conversion → Task into this actor). Exposes the latest snapshot for
/// the @MainActor commit task to poll.
///
/// Why an actor (vs the previous @MainActor in-line work):
/// - All parsing work moves off the main thread (codex tension #1).
/// - Per-line scheduling overhead drops from "Task hop per line" to
///   "one snapshot poll per 16ms frame".
/// - ChatItemBuilder + dedup state are isolated by the actor — no
///   manual locking, no @MainActor pinning.
actor StagingParser {
    private var builder = ChatItemBuilder()
    /// De-dupe ids so re-tailing the JSONL on file rotation doesn't
    /// double-render. Matches the legacy `seenIds` behavior.
    private var seenIds: Set<String> = []
    /// Bumps on every ingest that produced a delta. The @MainActor poll
    /// task uses this to short-circuit "nothing changed" commits.
    private var updateCounter: UInt64 = 0

    func ingest(_ line: ParsedLine) {
        for msg in line.messages {
            guard !seenIds.contains(msg.id) else { continue }
            seenIds.insert(msg.id)
            builder.ingest(msg)
        }
        updateCounter &+= 1
    }

    /// Flush any pending tool run (used at EOF or when caller wants a
    /// stable rendering). Bumps updateCounter so the poll task picks it
    /// up next frame.
    func flushPending() {
        builder.flushPending()
        updateCounter &+= 1
    }

    /// Snapshot the current builder state. The @MainActor commit task
    /// polls this every 16ms; if `updateCounter` hasn't advanced it
    /// short-circuits.
    func snapshot() -> SessionChatStore.ChatSnapshot {
        SessionChatStore.ChatSnapshot(
            items: builder.items,
            updateCounter: updateCounter
        )
    }
}

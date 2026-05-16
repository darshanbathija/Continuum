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
        public let planSteps: [PlanStep]
        public let sourceEntries: [SourceEntry]
        public let artifactEntries: [ArtifactEntry]
        /// Monotonic counter that bumps each time the snapshot updates.
        /// View code uses this for `.onChange` triggers instead of
        /// `items.last?.id`, which would change object identity per render.
        public let updateCounter: UInt64

        public init(
            items: [ChatItem],
            planSteps: [PlanStep] = [],
            sourceEntries: [SourceEntry] = [],
            artifactEntries: [ArtifactEntry] = [],
            updateCounter: UInt64
        ) {
            self.items = items
            self.planSteps = planSteps
            self.sourceEntries = sourceEntries
            self.artifactEntries = artifactEntries
            self.updateCounter = updateCounter
        }

        public static let empty = ChatSnapshot(items: [], updateCounter: 0)
    }

    @Published public private(set) var snapshot: ChatSnapshot = .empty
    /// Back-compat: views that still call `store.messages` keep working.
    /// Derived from `snapshot.items`; populated on each snapshot commit.
    /// Removed once all view code reads `snapshot.items` directly.
    @Published public private(set) var messages: [ChatMessage] = []
    @Published public private(set) var isLoading: Bool = true
    @Published public private(set) var lastError: String?
    /// External plan text (from AgentSession.planText). When set, the
    /// next staging snapshot extracts steps from this text and merges
    /// them with steps found in chat messages. The view doesn't have to
    /// observe AgentSession separately — `snapshot.planSteps` is the
    /// single source of truth for the Plan tab.
    public func setPlanText(_ text: String?) {
        Task { [staging] in await staging.setPlanText(text) }
    }

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

        // T4 reverse-tail progressive parse: synchronously kick off a
        // background task that reads the last ~256 KB of the JSONL and
        // ingests the newest ~50 messages into the staging actor FIRST.
        // The commit loop's first frame then shows the latest messages;
        // the head parse (JSONLTail from line 0) fills in older history
        // behind them. StagingParser dedups by id + sorts by timestamp,
        // so the final items array is in correct chronological order
        // regardless of arrival.
        let staging = self.staging
        let sessionURL = self.sessionFileURL
        Task.detached(priority: .userInitiated) {
            await Self.ingestTail(url: sessionURL, into: staging)
        }

        // JSONLTail runs on its background queue. The handler converts
        // [String: Any] → typed `ParsedLine` (Sendable) BEFORE crossing
        // into the actor — codex tension #7b: typed boundary, not raw
        // dictionaries.
        let tail = JSONLTail(fileURL: sessionFileURL) { json in
            guard let parsed = ParsedLine.from(json: json) else { return }
            Task { await staging.ingest(parsed) }
        }
        self.tail = tail
        tail.start()

        // Background commit task: every 16ms, snapshot the staging actor
        // and publish to main. Generation-token guard suppresses any
        // commits from stale parses (codex tension #6). T14 signposts
        // make each batch visible in Instruments → Animation Hitches.
        commitTask = Task.detached(priority: .userInitiated) { [weak self] in
            var lastCommittedCounter: UInt64 = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 16_000_000)
                let next = await staging.snapshot()
                guard next.updateCounter != lastCommittedCounter else { continue }
                let signpostID = OSSignpostID(log: chatPerfLog)
                os_signpost(.begin, log: chatPerfLog, name: "staging-parse-batch",
                            signpostID: signpostID,
                            "items=%d counter=%llu",
                            next.items.count, next.updateCounter)
                lastCommittedCounter = next.updateCounter
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    guard self.parseGeneration == generation else { return }
                    self.snapshot = next
                    // Back-compat: rebuild `messages` array from the
                    // snapshot's items. Drops once all views read
                    // snapshot.items directly.
                    self.messages = Self.flattenMessages(from: next.items)
                }
                os_signpost(.end, log: chatPerfLog, name: "staging-parse-batch",
                            signpostID: signpostID)
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

    /// T4: read the last ~256 KB of the JSONL, parse complete lines, and
    /// ingest into the staging actor. The first line in the chunk is
    /// likely partial (we seeked mid-line) so we skip to the first newline
    /// before parsing. Fail-quiet on any error — the head parse via
    /// JSONLTail will cover what we missed.
    private nonisolated static func ingestTail(
        url: URL, into staging: StagingParser
    ) async {
        let signpostID = OSSignpostID(log: chatPerfLog)
        os_signpost(.begin, log: chatPerfLog, name: "tail-read",
                    signpostID: signpostID,
                    "path=%{public}@", url.lastPathComponent)
        defer {
            os_signpost(.end, log: chatPerfLog, name: "tail-read",
                        signpostID: signpostID)
        }
        guard let fh = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? fh.close() }
        // Get file size; if smaller than 256 KB read the whole thing.
        guard let size = (try? fh.seekToEnd()) else { return }
        let chunkSize: UInt64 = 256 * 1024
        let start: UInt64 = size > chunkSize ? size - chunkSize : 0
        do { try fh.seek(toOffset: start) } catch { return }
        guard let bytes = try? fh.readToEnd(), !bytes.isEmpty else { return }

        // If we started mid-file, skip to first newline (drop the partial
        // leading line). When start==0 we begin at byte 0 — keep everything.
        var slice = bytes[bytes.startIndex...]
        if start > 0, let nl = slice.firstIndex(of: 0x0A) {
            slice = bytes[bytes.index(after: nl)...]
        }
        // Parse each complete line; ingest in order.
        var lineStart = slice.startIndex
        while lineStart < slice.endIndex {
            let newlineIdx = slice[lineStart...].firstIndex(of: 0x0A) ?? slice.endIndex
            let lineBytes = slice[lineStart..<newlineIdx]
            lineStart = (newlineIdx < slice.endIndex)
                ? slice.index(after: newlineIdx)
                : slice.endIndex
            guard !lineBytes.isEmpty else { continue }
            guard let json = (try? JSONSerialization.jsonObject(with: lineBytes)) as? [String: Any] else { continue }
            guard let parsed = ParsedLine.from(json: json) else { continue }
            await staging.ingest(parsed)
        }
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
    /// Messages kept in chronological order (by `at` timestamp, tiebreak
    /// by stable id). Insertion-sorted on ingest. This lets the reverse-
    /// tail parser (T4) ingest the newest 50 messages FIRST without the
    /// items array landing in tail-then-head order — snapshot() rebuilds
    /// items from this sorted list so chronological order is preserved
    /// regardless of arrival order. The seenIds dedup makes the head
    /// parse a no-op for any line the tail already covered.
    private var sortedMessages: [ChatMessage] = []
    private var seenIds: Set<String> = []
    /// External plan text (AgentSession.planText) injected via
    /// `SessionChatStore.setPlanText`. Drives the `planSteps` precompute
    /// alongside steps mined from assistant messages.
    private var planText: String? = nil
    /// Bumps on every ingest that produced a delta. The @MainActor poll
    /// task uses this to short-circuit "nothing changed" commits.
    private var updateCounter: UInt64 = 0
    /// Cached derived state rebuilt on snapshot() request. Invalidated
    /// whenever sortedMessages or planText changes.
    private var cachedSnapshot: SessionChatStore.ChatSnapshot = .empty
    private var cachedCounter: UInt64 = 0

    func ingest(_ line: ParsedLine) {
        var anyAppended = false
        for msg in line.messages {
            guard !seenIds.contains(msg.id) else { continue }
            seenIds.insert(msg.id)
            let idx = insertIndex(for: msg)
            sortedMessages.insert(msg, at: idx)
            anyAppended = true
        }
        if anyAppended {
            updateCounter &+= 1
        }
    }

    func setPlanText(_ text: String?) {
        guard planText != text else { return }
        planText = text
        updateCounter &+= 1
    }

    /// Snapshot the current state. Lazy-rebuilds derived arrays only when
    /// sortedMessages / planText changed since last snapshot. All passes
    /// run on the staging actor — never on main.
    func snapshot() -> SessionChatStore.ChatSnapshot {
        if cachedCounter != updateCounter {
            // 1) items[] from chronological messages
            var builder = ChatItemBuilder()
            for msg in sortedMessages {
                builder.ingest(msg)
            }
            builder.flushPending()
            let items = builder.items

            // 2) planSteps with isComplete flags
            let steps = computePlanSteps(items: items, planText: planText)

            // 3) source entries (Read / Grep / Glob / WebFetch / WebSearch)
            let sources = computeSourceEntries(messages: sortedMessages)

            // 4) artifact entries (Write tool calls with artifact-extension paths)
            let artifacts = computeArtifactEntries(messages: sortedMessages)

            cachedSnapshot = SessionChatStore.ChatSnapshot(
                items: items,
                planSteps: steps,
                sourceEntries: sources,
                artifactEntries: artifacts,
                updateCounter: updateCounter
            )
            cachedCounter = updateCounter
        }
        return cachedSnapshot
    }

    // MARK: - Derived-state computations

    private func computePlanSteps(items: [ChatItem], planText: String?) -> [PlanStep] {
        var stepTexts: [String] = []
        var seen: Set<String> = []
        let candidates: [String] = [planText ?? ""] + items.compactMap { item in
            if case .message(let m) = item, m.kind == .assistantText { return m.body }
            return nil
        }
        for body in candidates {
            for step in Self.extractStepCandidates(from: body) {
                let key = String(step.lowercased().prefix(40))
                if !seen.contains(key) {
                    seen.insert(key)
                    stepTexts.append(step)
                    if stepTexts.count >= 24 { break }
                }
            }
            if stepTexts.count >= 24 { break }
        }
        // Mark each step complete if a SUBSEQUENT assistant message or
        // tool_call references the step's first ~30 chars. O(M × candidates)
        // — fine for M ≤ 24.
        return stepTexts.enumerated().map { idx, text in
            let needle = String(text.lowercased().prefix(30))
            let complete = candidates.contains { body in
                body.lowercased().contains(needle) && body != text
            }
            return PlanStep(id: "step-\(idx)", text: text, isComplete: complete)
        }
    }

    private static func extractStepCandidates(from body: String) -> [String] {
        var out: [String] = []
        for raw in body.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let match = line.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
                let content = String(line[match.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !content.isEmpty { out.append(content) }
                continue
            }
            if let match = line.range(of: #"^Step\s+\d+:?\s+"#,
                                       options: [.regularExpression, .caseInsensitive]) {
                let content = String(line[match.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !content.isEmpty { out.append(content) }
            }
        }
        return out
    }

    private func computeSourceEntries(messages: [ChatMessage]) -> [SourceEntry] {
        var files: [String: Int] = [:]
        var urls: [String: Int] = [:]
        for msg in messages where msg.kind == .toolCall {
            switch msg.title {
            case "Read", "Edit", "Write":
                let path = msg.body.trimmingCharacters(in: .whitespaces)
                guard !path.isEmpty else { continue }
                files[path, default: 0] += 1
            case "Glob", "Grep":
                let pattern = msg.body.trimmingCharacters(in: .whitespaces)
                guard !pattern.isEmpty else { continue }
                files[pattern, default: 0] += 1
            case "WebFetch", "WebSearch":
                let url = msg.body.trimmingCharacters(in: .whitespaces)
                guard !url.isEmpty else { continue }
                urls[url, default: 0] += 1
            default:
                break
            }
        }
        var out: [SourceEntry] = []
        for (path, count) in files.sorted(by: { $0.value > $1.value }) {
            out.append(SourceEntry(
                id: "f:\(path)", kind: .file, label: path,
                payload: path, count: count
            ))
        }
        for (url, count) in urls.sorted(by: { $0.value > $1.value }) {
            out.append(SourceEntry(
                id: "u:\(url)", kind: .url, label: url,
                payload: url, count: count
            ))
        }
        return out
    }

    private static let artifactExtensions: Set<String> = [
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx",
        "png", "jpg", "jpeg", "gif", "svg", "webp", "tiff",
        "mp4", "mov", "mp3", "wav",
        "csv", "tsv",
        "zip", "tar", "gz",
    ]

    private func computeArtifactEntries(messages: [ChatMessage]) -> [ArtifactEntry] {
        var seen: Set<String> = []
        var out: [ArtifactEntry] = []
        for msg in messages where msg.kind == .toolCall && msg.title == "Write" {
            let path = msg.body.trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty else { continue }
            let ext = (path as NSString).pathExtension.lowercased()
            guard Self.artifactExtensions.contains(ext) else { continue }
            // For relative paths, we keep them as-is — the view layer
            // resolves to absolute by combining with session.repoKey.
            guard !seen.contains(path) else { continue }
            seen.insert(path)
            out.append(ArtifactEntry(path: path))
        }
        return out
    }

    /// Binary-search insertion index keeping `sortedMessages` ordered by
    /// `(at, id)`. Ties on timestamp broken by stable id so two messages
    /// in the same JSONL line (e.g. tool_use + tool_result blocks) keep
    /// a deterministic order across runs.
    private func insertIndex(for msg: ChatMessage) -> Int {
        var lo = 0
        var hi = sortedMessages.count
        while lo < hi {
            let mid = (lo + hi) / 2
            let m = sortedMessages[mid]
            if m.at < msg.at || (m.at == msg.at && m.id < msg.id) {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return lo
    }
}

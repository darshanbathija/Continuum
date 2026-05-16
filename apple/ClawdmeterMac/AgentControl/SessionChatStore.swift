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
        /// Fresh input tokens (`message.usage.input_tokens`). Held
        /// separately from cache_creation and cache_read so the cost
        /// estimator can apply the right rate per category — Sonnet's
        /// cache_read rate is 10x cheaper than fresh input.
        public let totalInputTokens: Int
        public let totalOutputTokens: Int
        public let totalCacheCreationTokens: Int
        public let totalCacheReadTokens: Int
        /// Last assistant message's `message.model` field. We use the
        /// latest one because users sometimes switch mid-session via
        /// `/model`; the most recent tokens are billed at the most
        /// recent model's rates. Nil for sessions with no Claude
        /// assistant turns ingested yet.
        public let modelHint: String?
        /// Timestamp of the latest ingested message. Drives the
        /// "thinking" indicator — the chat shows the running animation
        /// when the file has been touched within the activity window.
        public let lastEventAt: Date?
        /// Monotonic counter that bumps each time the snapshot updates.
        /// View code uses this for `.onChange` triggers instead of
        /// `items.last?.id`, which would change object identity per render.
        public let updateCounter: UInt64

        public init(
            items: [ChatItem],
            planSteps: [PlanStep] = [],
            sourceEntries: [SourceEntry] = [],
            artifactEntries: [ArtifactEntry] = [],
            totalInputTokens: Int = 0,
            totalOutputTokens: Int = 0,
            totalCacheCreationTokens: Int = 0,
            totalCacheReadTokens: Int = 0,
            modelHint: String? = nil,
            lastEventAt: Date? = nil,
            updateCounter: UInt64
        ) {
            self.items = items
            self.planSteps = planSteps
            self.sourceEntries = sourceEntries
            self.artifactEntries = artifactEntries
            self.totalInputTokens = totalInputTokens
            self.totalOutputTokens = totalOutputTokens
            self.totalCacheCreationTokens = totalCacheCreationTokens
            self.totalCacheReadTokens = totalCacheReadTokens
            self.modelHint = modelHint
            self.lastEventAt = lastEventAt
            self.updateCounter = updateCounter
        }

        public static let empty = ChatSnapshot(items: [], updateCounter: 0)

        /// Headline tokens for the activity strip — sum of all four
        /// categories. Matches the analytics layer's `TokenTotals.totalTokens`.
        public var totalTokens: Int {
            totalInputTokens + totalOutputTokens
                + totalCacheCreationTokens + totalCacheReadTokens
        }
    }

    @Published public private(set) var snapshot: ChatSnapshot = .empty
    /// Back-compat: views that still call `store.messages` keep working.
    /// Derived lazily from `snapshot.items` — was previously a parallel
    /// `@Published` rebuilt on every 16ms commit (allocating a fresh
    /// flat array on the main thread). With the snapshot now driving
    /// all view invalidations, the read sites (PRMirror.findPRURL,
    /// SessionsModel.filter search, PoppedChatThread ForEach) re-flatten
    /// only when they actually consume it. ObservableObject notification
    /// happens via `$snapshot` so subscribers still see updates.
    public var messages: [ChatMessage] {
        Self.flattenMessages(from: snapshot.items)
    }
    @Published public private(set) var isLoading: Bool = true
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
    /// Reverse-tail ingest task — tracked so `stop()` cancels it (was
    /// previously fire-and-forget, so a `stop()` followed by `start()`
    /// could let the old reverse-tail's late ingests bleed into the new
    /// parse generation through the shared StagingParser).
    private var ingestTailTask: Task<Void, Never>?
    /// Per-line ingest tasks spawned by the JSONLTail handler. These are
    /// also tracked so `stop()` cancels them; combined with the per-task
    /// generation check inside the ingest closure, this closes the
    /// "stop() doesn't stop all writers" race surfaced in /review.
    private var perLineIngestTasks: [Task<Void, Never>] = []

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

        // Reset the staging actor so a start-after-stop cycle doesn't
        // bleed stale messages / seenIds / derived counters from the
        // previous generation. Fire-and-forget: the await happens inside
        // a detached Task so start() stays synchronous from the caller's
        // perspective. Subsequent reverse-tail and per-line ingests
        // serialize behind the reset via actor ordering.
        let staging = self.staging
        Task.detached(priority: .userInitiated) {
            await staging.reset()
        }

        // T4 reverse-tail progressive parse: kick off a background task
        // that reads the last ~256 KB of the JSONL and ingests the newest
        // ~50 messages into the staging actor FIRST. The commit loop's
        // first frame then shows the latest messages; the head parse
        // (JSONLTail from line 0) fills in older history behind them.
        // StagingParser dedups by id + sorts by timestamp, so the final
        // items array is in correct chronological order regardless of
        // arrival.
        let sessionURL = self.sessionFileURL
        ingestTailTask = Task.detached(priority: .userInitiated) { [weak self] in
            await Self.ingestTail(
                url: sessionURL,
                into: staging,
                generation: generation,
                store: self
            )
        }

        // JSONLTail runs on its background queue. The handler converts
        // [String: Any] → typed `ParsedLine` (Sendable) BEFORE crossing
        // into the actor — codex tension #7b: typed boundary, not raw
        // dictionaries. The per-line task is tracked on `self` so
        // `stop()` can cancel it; the closure-level generation check
        // also drops late ingests from a prior parse generation.
        let tail = JSONLTail(fileURL: sessionFileURL) { [weak self] json in
            guard let parsed = ParsedLine.from(json: json) else { return }
            let task = Task { [weak self] in
                guard let self else { return }
                // The MainActor read is necessary because parseGeneration
                // lives on self (@MainActor). Snapshot it once then drop
                // the hop.
                let currentGen = await MainActor.run { self.parseGeneration }
                guard currentGen == generation else { return }
                await staging.ingest(parsed)
            }
            // Track the task so stop() can cancel any in-flight ingests.
            Task { @MainActor [weak self] in
                self?.perLineIngestTasks.append(task)
            }
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
                    // No `messages` rebuild here — it's a computed
                    // property derived from `snapshot.items` on demand,
                    // so we get a single objectWillChange per commit
                    // rather than two parallel @Published mutations.
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
                            "messageCount=%d", self.snapshot.items.count)
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
        ingestTailTask?.cancel()
        ingestTailTask = nil
        // Cancel any per-line ingest tasks that haven't finished yet.
        // The generation guard inside each task is the primary defense;
        // explicit cancel just shortens the time window during which a
        // stopped store's queued ingests can still hit the actor.
        for task in perLineIngestTasks { task.cancel() }
        perLineIngestTasks.removeAll(keepingCapacity: false)
        tail?.stop()
        tail = nil
        // Close out the session-open signpost if start()'s 500ms isLoading
        // task didn't reach it before stop(). Without this, Instruments
        // traces show an unbounded `session-open` interval that never
        // ends — confusing during perf analysis.
        if let id = startSignpostID {
            os_signpost(.end, log: chatPerfLog, name: "session-open",
                        signpostID: id,
                        "messageCount=%d stopped=1", self.snapshot.items.count)
            startSignpostID = nil
        }
    }

    /// Safety net for the rare case where a caller drops the store
    /// without calling `stop()` first. `commitTask` is detached and
    /// keeps spinning the 16ms poll until cancelled; cancelling here
    /// ensures the only way for the task to outlive the store is the
    /// `[weak self]` guard at the MainActor hop (which still exits
    /// cleanly, just one frame later than necessary).
    deinit {
        commitTask?.cancel()
        tail?.stop()
    }

    /// T4: read the last ~256 KB of the JSONL, parse complete lines, and
    /// ingest into the staging actor. The first line in the chunk is
    /// likely partial (we seeked mid-line) so we skip to the first newline
    /// before parsing. Fail-quiet on any error — the head parse via
    /// JSONLTail will cover what we missed.
    ///
    /// The `generation` argument is captured at `start()` time and
    /// checked before each ingest so a `stop()` that races the
    /// reverse-tail can prevent stale ingests from polluting a future
    /// parse. `Task.checkCancellation()` is the primary defense; the
    /// generation check is the belt to the cancellation suspenders.
    private nonisolated static func ingestTail(
        url: URL,
        into staging: StagingParser,
        generation: UInt64,
        store: SessionChatStore?
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
        // Parse each complete line; ingest in order. Cancellation +
        // generation check before each ingest keeps a stale tail from
        // contaminating a new parse generation after stop() → start().
        var lineStart = slice.startIndex
        while lineStart < slice.endIndex {
            if Task.isCancelled { return }
            let newlineIdx = slice[lineStart...].firstIndex(of: 0x0A) ?? slice.endIndex
            let lineBytes = slice[lineStart..<newlineIdx]
            lineStart = (newlineIdx < slice.endIndex)
                ? slice.index(after: newlineIdx)
                : slice.endIndex
            guard !lineBytes.isEmpty else { continue }
            guard let json = (try? JSONSerialization.jsonObject(with: lineBytes)) as? [String: Any] else { continue }
            guard let parsed = ParsedLine.from(json: json) else { continue }
            if let store {
                let currentGen = await MainActor.run { store.parseGeneration }
                guard currentGen == generation else { return }
            }
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

    // MARK: - Helpers (used by ParsedLine.from)
    // The legacy main-actor `applyLine` / `handleUser` / `handleAssistant`
    // path was replaced by the off-main `ParsedLine.from(json:)` →
    // `StagingParser.ingest(_:)` pipeline. Helpers below are marked
    // `nonisolated` so ParsedLine.from can call them from any context.

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

    /// Codex tool-input summarizer. Thin wrapper over the Shared
    /// `CodexJSONLParser.summarizeInput` so iOS + tests can use the same
    /// logic. The Mac-side decoder calls this through the parser
    /// directly; this wrapper exists so the Claude-side helpers can keep
    /// addressing Codex names without importing CodexJSONLParser at
    /// every callsite.
    nonisolated static func summarizeCodexInput(
        _ dict: [String: Any], for tool: String, fallback: String
    ) -> String {
        CodexJSONLParser.summarizeInput(dict, for: tool, fallback: fallback)
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
        case "exec_command", "shell", "spawn_agent", "apply_patch":
            // Codex tool detail — Shared parser owns the schema, so
            // adding a new Codex tool only requires updating one site.
            return CodexJSONLParser.expandedDetail(dict, for: tool)
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
    /// Per-category token deltas pulled from `message.usage` on Claude
    /// assistant turns. Each category is billed at a different rate —
    /// cache_read at 10% of fresh input, cache_creation at 125% — so
    /// keeping them separate is required for an accurate cost estimate.
    /// All zero for user/meta lines and for Codex (Codex's token totals
    /// live in `event_msg.token_count` events the chat parser doesn't
    /// surface).
    let deltaInputTokens: Int
    let deltaOutputTokens: Int
    let deltaCacheCreationTokens: Int
    let deltaCacheReadTokens: Int
    /// Model the message was billed against (`message.model`). Used as
    /// the cost-estimator hint — we pick the latest seen, since users
    /// sometimes switch mid-session.
    let model: String?

    /// Convert a raw JSONL dict into a typed ParsedLine. Returns `nil` for
    /// lines we don't surface (queue-operation, last-prompt, attachment,
    /// etc.) or malformed lines. Pure value transform.
    ///
    /// Both Claude and Codex JSONLs flow through here:
    /// - Claude lines have `type: "user" | "assistant"` at the top level
    ///   and a `message: {content, usage}` body. We decode them via
    ///   `decodeUser` / `decodeAssistant`.
    /// - Codex lines have `type: "response_item"` with a `payload` carrying
    ///   `type: "message" | "function_call" | "function_call_output" |
    ///   "reasoning"` and a role (`user | assistant | developer`). The
    ///   shape is wildly different from Claude's; `decodeCodexResponseItem`
    ///   handles it.
    static func from(json: [String: Any]) -> ParsedLine? {
        let at = SessionChatStore.parseTimestamp(json) ?? Date()
        let type = json["type"] as? String ?? ""
        switch type {
        case "user":
            return decodeUser(json: json, at: at)
        case "assistant":
            return decodeAssistant(json: json, at: at)
        case "response_item":
            return decodeCodexResponseItem(json: json, at: at)
        default:
            return nil
        }
    }

    /// Codex JSONL chat decoder. Thin wrapper over
    /// `CodexJSONLParser.decodeResponseItem` — the pure transform lives
    /// in Shared (testable + iOS-readable). This wrapper threads the
    /// per-line `stableId` cursor through and wraps the resulting
    /// `[ChatMessage]` in a `ParsedLine` for the Mac staging pipeline.
    private static func decodeCodexResponseItem(json: [String: Any], at: Date) -> ParsedLine? {
        let messages = CodexJSONLParser.decodeResponseItem(json: json, at: at) { suffix in
            SessionChatStore.stableId(json, suffix: suffix)
        }
        guard !messages.isEmpty else { return nil }
        return ParsedLine(
            timestamp: at, messages: messages,
            deltaInputTokens: 0, deltaOutputTokens: 0,
            deltaCacheCreationTokens: 0, deltaCacheReadTokens: 0,
            model: nil
        )
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
        return ParsedLine(
            timestamp: at, messages: out,
            deltaInputTokens: 0, deltaOutputTokens: 0,
            deltaCacheCreationTokens: 0, deltaCacheReadTokens: 0,
            model: nil
        )
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
        // Split Claude's `message.usage` into the four categories
        // ClaudeUsageParser uses for analytics. Conflating them into a
        // single `inputTokens` value undercounted cost by ~80x in the
        // activity strip because cache_read is billed at 10% of fresh
        // input AND because Pricing.cost previously silently dropped
        // input tokens past the 200K boundary for un-tiered models.
        var inTok = 0
        var outTok = 0
        var cacheCreate = 0
        var cacheRead = 0
        if let usage = message["usage"] as? [String: Any] {
            inTok = (usage["input_tokens"] as? Int) ?? 0
            outTok = (usage["output_tokens"] as? Int) ?? 0
            cacheCreate = (usage["cache_creation_input_tokens"] as? Int) ?? 0
            cacheRead = (usage["cache_read_input_tokens"] as? Int) ?? 0
        }
        let model = (message["model"] as? String)
        return ParsedLine(
            timestamp: at, messages: out,
            deltaInputTokens: inTok, deltaOutputTokens: outTok,
            deltaCacheCreationTokens: cacheCreate, deltaCacheReadTokens: cacheRead,
            model: model
        )
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
    /// Messages kept in chronological order (by `at` timestamp, with a
    /// kind-based tiebreak — see `insertIndex(for:)`). The reverse-tail
    /// parser ingests newest-first; the head parse ingests oldest-first;
    /// both converge into one sorted array via insertion. The seenIds
    /// dedup makes the head parse a no-op for any line the tail covered.
    private var sortedMessages: [ChatMessage] = []
    private var seenIds: Set<String> = []
    /// External plan text (AgentSession.planText) injected via
    /// `SessionChatStore.setPlanText`. Drives the `planSteps` precompute
    /// alongside steps mined from assistant messages.
    private var planText: String? = nil
    /// Accumulated tokens for the session metadata strip — split into
    /// the four billable categories so the cost estimator can apply
    /// the right rate per category. Pulled from `message.usage` on
    /// Claude assistant turns; all zero for Codex (handled in analytics).
    private var totalInputTokens: Int = 0
    private var totalOutputTokens: Int = 0
    private var totalCacheCreationTokens: Int = 0
    private var totalCacheReadTokens: Int = 0
    /// Latest `message.model` value the staging parser saw. The activity
    /// strip's cost estimator uses this — sessions can switch mid-stream
    /// via `/model` and the most recent rate should apply going forward.
    private var modelHint: String? = nil
    /// Timestamp of the most-recently ingested line. The chat's
    /// "thinking" indicator pulses when this is within the activity
    /// window (Date() - 30s).
    private var lastEventAt: Date? = nil
    /// Bumps on every ingest that produced a delta. The @MainActor poll
    /// task uses this to short-circuit "nothing changed" commits.
    private var updateCounter: UInt64 = 0
    /// Cached derived state rebuilt on snapshot() request. Invalidated
    /// whenever sortedMessages or planText changes.
    private var cachedSnapshot: SessionChatStore.ChatSnapshot = .empty
    private var cachedCounter: UInt64 = 0

    // --- Incremental derived state (hardening sprint) ----------------------
    // Sources / artifacts / lowercased bodies are maintained on each
    // ingest rather than recomputed during snapshot(). Trade: each ingest
    // does O(1) extra work; snapshot() drops from O(N + M×candidate.length)
    // to O(K log K) for the sources sort + O(M × 50) for the plan-step
    // scan. With N=5,536 and M=24, this is a measurable difference
    // during the backfill window where the snapshot() poll fires every
    // 16 ms and the original implementation rebuilt all four derived
    // arrays from scratch every tick.

    private var fileCounts: [String: Int] = [:]
    private var urlCounts: [String: Int] = [:]
    private var artifactPaths: [String] = []          // insertion-order
    private var seenArtifactPaths: Set<String> = []

    /// Last ~200 assistant-message bodies, lowercased once at ingest time
    /// and reused for plan-step completion detection. The original code
    /// called `.lowercased()` on every candidate inside the M-step loop;
    /// for sessions with long assistant bodies this allocated tens of MB
    /// per snapshot during backfill.
    private var lowercasedAssistantBodies: [String] = []
    private static let maxCachedAssistantBodies = 200

    /// Step-completion scan window — only the most-recent N assistant
    /// bodies are checked. Steps from late in the conversation are the
    /// ones that matter for the "is this complete" heuristic; older
    /// bodies that already exist on screen don't need to be re-scanned
    /// every tick.
    private static let stepCompletionScanWindow = 50

    /// Snapshot-rebuild throttle. During a high-rate backfill the
    /// `updateCounter` changes on every ingest; without a throttle, the
    /// 16 ms commit task rebuilds derived state on every tick. We cap
    /// rebuilds to once per `minRebuildIntervalNanos` so the actor can
    /// spend its time ingesting rather than re-publishing. Steady-state
    /// (low ingest rate) is unaffected — the first rebuild after a quiet
    /// window is always serviced immediately.
    private var lastSnapshotRebuildNS: UInt64 = 0
    private static let minRebuildIntervalNanos: UInt64 = 100_000_000  // 100 ms

    func ingest(_ line: ParsedLine) {
        var anyAppended = false
        for msg in line.messages {
            guard !seenIds.contains(msg.id) else { continue }
            seenIds.insert(msg.id)
            let idx = insertIndex(for: msg)
            sortedMessages.insert(msg, at: idx)
            ingestIntoDerivedIndexes(msg)
            anyAppended = true
        }
        if anyAppended {
            updateCounter &+= 1
            // Activity tracking: the metadata strip uses this to decide
            // whether the "thinking" indicator should pulse. We keep
            // the latest line's timestamp (not Date()) so a backfill of
            // historical messages doesn't falsely show the agent as
            // active.
            if let stamp = line.messages.map(\.at).max() {
                if lastEventAt == nil || stamp > lastEventAt! {
                    lastEventAt = stamp
                }
            }
            totalInputTokens += line.deltaInputTokens
            totalOutputTokens += line.deltaOutputTokens
            totalCacheCreationTokens += line.deltaCacheCreationTokens
            totalCacheReadTokens += line.deltaCacheReadTokens
            // Take the latest non-empty model hint. Reverse-tail ingests
            // can arrive out of order, but the latest timestamp wins
            // because we re-walk this on every snapshot rebuild anyway.
            if let m = line.model, !m.isEmpty {
                modelHint = m
            }
        }
    }

    func setPlanText(_ text: String?) {
        guard planText != text else { return }
        planText = text
        updateCounter &+= 1
    }

    /// Hardening: clear all accumulated state without re-instantiating
    /// the actor. Called by `SessionChatStore.start()` when re-entering
    /// after a prior `stop()` so untracked in-flight ingests can't bleed
    /// stale messages into a fresh session.
    func reset() {
        sortedMessages.removeAll(keepingCapacity: false)
        seenIds.removeAll(keepingCapacity: false)
        planText = nil
        fileCounts.removeAll(keepingCapacity: false)
        urlCounts.removeAll(keepingCapacity: false)
        artifactPaths.removeAll(keepingCapacity: false)
        seenArtifactPaths.removeAll(keepingCapacity: false)
        lowercasedAssistantBodies.removeAll(keepingCapacity: false)
        totalInputTokens = 0
        totalOutputTokens = 0
        totalCacheCreationTokens = 0
        totalCacheReadTokens = 0
        modelHint = nil
        lastEventAt = nil
        cachedSnapshot = .empty
        cachedCounter = 0
        updateCounter = 0
        lastSnapshotRebuildNS = 0
    }

    /// Snapshot the current state. Two short-circuit paths:
    /// 1. `cachedCounter == updateCounter` — nothing changed, return cache.
    /// 2. Less than `minRebuildIntervalNanos` since the previous rebuild
    ///    AND we already have a non-empty cached snapshot — under
    ///    backfill, this keeps the poller from doing repeated rebuild
    ///    work while ingest is still streaming.
    func snapshot() -> SessionChatStore.ChatSnapshot {
        guard cachedCounter != updateCounter else { return cachedSnapshot }
        let nowNS = DispatchTime.now().uptimeNanoseconds
        if cachedCounter != 0,
           nowNS &- lastSnapshotRebuildNS < Self.minRebuildIntervalNanos {
            // Within the throttle window — defer the rebuild. The commit
            // loop will call snapshot() again on the next 16 ms tick and
            // we'll eventually fall through this guard.
            return cachedSnapshot
        }

        // 1) items[] — has to be a full rebuild because ChatItemBuilder's
        //    run-grouping depends on chronological order, and the reverse-
        //    tail + head parses both insert into the middle of
        //    sortedMessages until they meet.
        var builder = ChatItemBuilder()
        for msg in sortedMessages {
            builder.ingest(msg)
        }
        builder.flushPending()
        let items = builder.items

        // 2) planSteps — bounded scan against precomputed lowercased
        //    bodies. The candidate-extraction pass walks items once
        //    (skipping non-assistant), but the completion check no longer
        //    re-lowercases full bodies per step.
        let steps = computePlanStepsIncremental(items: items)

        // 3) source entries — sort the incremental dicts; no full scan.
        var sources: [SourceEntry] = []
        for (path, count) in fileCounts.sorted(by: { $0.value > $1.value }) {
            sources.append(SourceEntry(
                id: "f:\(path)", kind: .file, label: path,
                payload: path, count: count
            ))
        }
        for (url, count) in urlCounts.sorted(by: { $0.value > $1.value }) {
            sources.append(SourceEntry(
                id: "u:\(url)", kind: .url, label: url,
                payload: url, count: count
            ))
        }

        // 4) artifacts — maintained as an insertion-ordered list.
        let artifacts = artifactPaths.map { ArtifactEntry(path: $0) }

        cachedSnapshot = SessionChatStore.ChatSnapshot(
            items: items,
            planSteps: steps,
            sourceEntries: sources,
            artifactEntries: artifacts,
            totalInputTokens: totalInputTokens,
            totalOutputTokens: totalOutputTokens,
            totalCacheCreationTokens: totalCacheCreationTokens,
            totalCacheReadTokens: totalCacheReadTokens,
            modelHint: modelHint,
            lastEventAt: lastEventAt,
            updateCounter: updateCounter
        )
        cachedCounter = updateCounter
        lastSnapshotRebuildNS = nowNS
        return cachedSnapshot
    }

    // MARK: - Incremental derived-state maintenance

    /// Update fileCounts/urlCounts/artifactPaths/lowercasedAssistantBodies
    /// in O(1) (amortized) on each new message. The original implementation
    /// rebuilt these by scanning all of sortedMessages on every snapshot.
    private func ingestIntoDerivedIndexes(_ msg: ChatMessage) {
        switch msg.kind {
        case .assistantText:
            lowercasedAssistantBodies.append(msg.body.lowercased())
            if lowercasedAssistantBodies.count > Self.maxCachedAssistantBodies {
                let drop = lowercasedAssistantBodies.count - Self.maxCachedAssistantBodies
                lowercasedAssistantBodies.removeFirst(drop)
            }
        case .toolCall:
            let trimmed = msg.body.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            switch msg.title {
            case "Read", "Edit":
                fileCounts[trimmed, default: 0] += 1
            case "Write":
                fileCounts[trimmed, default: 0] += 1
                let ext = (trimmed as NSString).pathExtension.lowercased()
                if Self.artifactExtensions.contains(ext),
                   !seenArtifactPaths.contains(trimmed) {
                    seenArtifactPaths.insert(trimmed)
                    artifactPaths.append(trimmed)
                }
            case "Glob", "Grep":
                fileCounts[trimmed, default: 0] += 1
            case "WebFetch", "WebSearch":
                urlCounts[trimmed, default: 0] += 1
            default:
                break
            }
        case .userText, .toolResult, .meta:
            break
        }
    }

    // MARK: - Plan-step extraction

    private func computePlanStepsIncremental(items: [ChatItem]) -> [PlanStep] {
        // Step candidates come from planText first, then assistant
        // messages in chronological order, capped at 24.
        var stepTexts: [String] = []
        var seen: Set<String> = []
        let plan = planText ?? ""
        for step in Self.extractStepCandidates(from: plan) {
            let key = String(step.lowercased().prefix(40))
            if !seen.contains(key) {
                seen.insert(key)
                stepTexts.append(step)
                if stepTexts.count >= 24 { break }
            }
        }
        if stepTexts.count < 24 {
            for item in items {
                if case .message(let m) = item, m.kind == .assistantText {
                    for step in Self.extractStepCandidates(from: m.body) {
                        let key = String(step.lowercased().prefix(40))
                        if !seen.contains(key) {
                            seen.insert(key)
                            stepTexts.append(step)
                            if stepTexts.count >= 24 { break }
                        }
                    }
                    if stepTexts.count >= 24 { break }
                }
            }
        }

        // Completion check: scan only the most-recent N lowercased
        // assistant bodies (already cached at ingest time). Plus the
        // planText, lowercased once.
        let recentBodies = lowercasedAssistantBodies
            .suffix(Self.stepCompletionScanWindow)
        let lcPlan = plan.isEmpty ? "" : plan.lowercased()
        return stepTexts.enumerated().map { idx, text in
            let needle = String(text.lowercased().prefix(30))
            let needleLen = needle.count
            // Self-match guard: skip the body whose own first-30 chars
            // are the needle (the body the step came from).
            let inRecent = recentBodies.contains { body in
                guard body.contains(needle) else { return false }
                // Cheap self-match filter — if the recent body STARTS
                // with the needle and is short enough to be just the
                // step text repeated, treat as self-reference. Otherwise
                // a later mention counts.
                if body.hasPrefix(needle) && body.count <= needleLen + 4 {
                    return false
                }
                return true
            }
            let inPlan = !lcPlan.isEmpty && lcPlan.contains(needle)
                && !(lcPlan.hasPrefix(needle) && lcPlan.count <= needleLen + 4)
            return PlanStep(
                id: "step-\(idx)", text: text, isComplete: inRecent || inPlan
            )
        }
    }

    /// Forwarder kept on StagingParser for call-site brevity; the
    /// canonical implementation lives in `ChatMessageOrdering` in the
    /// Shared module so unit tests can exercise it directly.
    private static func extractStepCandidates(from body: String) -> [String] {
        ChatMessageOrdering.extractStepCandidates(from: body)
    }

    private static let artifactExtensions: Set<String> = [
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx",
        "png", "jpg", "jpeg", "gif", "svg", "webp", "tiff",
        "mp4", "mov", "mp3", "wav",
        "csv", "tsv",
        "zip", "tar", "gz",
    ]

    /// Binary-search insertion index keeping `sortedMessages` ordered by
    /// `(at, kindRank, id)` via the shared `ChatMessageOrdering`. The
    /// kind-based tiebreak fixes the previous `(at, id)` design that
    /// relied on `"call:" < "result:"` lexicographic ordering — fragile
    /// against any future change to Anthropic's id prefixes.
    private func insertIndex(for msg: ChatMessage) -> Int {
        var lo = 0
        var hi = sortedMessages.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if ChatMessageOrdering.precedes(sortedMessages[mid], msg) {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return lo
    }
}

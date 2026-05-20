import Foundation

// Pure value types for parsed chat content. All Sendable + Codable so they
// cross actor boundaries cleanly (closes the codex-flagged Sendable trap
// with [String: Any] crossing into MainActor).
//
// UI types (Color, NSWorkspace, QLPreviewView, MarkdownRenderer.Chunk) stay
// on the Mac side; this module is the data layer the views read.

/// One parsed line from a JSONL session file. Sendable / Codable / Hashable
/// so the staging parser can cross the actor boundary into MainActor without
/// `[String: Any]` casts.
public struct ChatMessage: Identifiable, Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable {
        case userText
        case assistantText
        case toolCall
        case toolResult
        case meta
    }

    public let id: String
    public let kind: Kind
    public let title: String     // tool name, "You", "Claude", "meta"
    public let body: String
    /// Optional detail line — e.g., the full Bash command when `body` is
    /// the human-readable description.
    public let detail: String?
    public let at: Date
    public let isError: Bool
    /// v0.5.5: structured Edit/MultiEdit/Write summary populated at parse
    /// time. Drives the specialized "Edited <file> +N -M" chat row that
    /// replaces the generic "Ran 1 command" card for file-edit tool
    /// calls. Nil for any other tool (Bash, Read, Grep, etc.) and for
    /// non-tool messages.
    public let editStats: EditStats?
    /// v0.5.6: structured AskUserQuestion payload populated at parse time
    /// when the assistant emits an `AskUserQuestion` tool_use. Drives the
    /// interactive tappable tray that replaces the generic "Ran 1
    /// command" card for AskUserQuestion calls. Nil for any other tool.
    public let askUserQuestion: AskUserQuestion?

    public init(
        id: String,
        kind: Kind,
        title: String,
        body: String,
        detail: String? = nil,
        at: Date,
        isError: Bool = false,
        editStats: EditStats? = nil,
        askUserQuestion: AskUserQuestion? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
        self.detail = detail
        self.at = at
        self.isError = isError
        self.editStats = editStats
        self.askUserQuestion = askUserQuestion
    }

    // Custom Decodable init so v0 messages persisted before the editStats
    // field landed still decode cleanly. `decodeIfPresent` defaults each
    // new field to nil; older messages decode without error.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.kind = try c.decode(Kind.self, forKey: .kind)
        self.title = try c.decode(String.self, forKey: .title)
        self.body = try c.decode(String.self, forKey: .body)
        self.detail = try c.decodeIfPresent(String.self, forKey: .detail)
        self.at = try c.decode(Date.self, forKey: .at)
        self.isError = (try? c.decode(Bool.self, forKey: .isError)) ?? false
        self.editStats = try c.decodeIfPresent(EditStats.self, forKey: .editStats)
        self.askUserQuestion = try c.decodeIfPresent(AskUserQuestion.self, forKey: .askUserQuestion)
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, title, body, detail, at, isError, editStats, askUserQuestion
    }
}

/// v0.5.6: parsed `AskUserQuestion` tool_use payload. Mirrors the input
/// shape Claude Code's `AskUserQuestion` tool emits — `questions: [...]`
/// each with a short header, a long question, and a list of options.
public struct AskUserQuestion: Hashable, Sendable, Codable {
    public struct Question: Hashable, Sendable, Codable {
        public let question: String
        public let header: String
        public let multiSelect: Bool
        public let options: [Option]

        public init(question: String, header: String, multiSelect: Bool, options: [Option]) {
            self.question = question
            self.header = header
            self.multiSelect = multiSelect
            self.options = options
        }
    }

    public struct Option: Hashable, Sendable, Codable, Identifiable {
        public let label: String
        public let description: String

        public var id: String { label }

        public init(label: String, description: String) {
            self.label = label
            self.description = description
        }
    }

    public let questions: [Question]

    public init(questions: [Question]) {
        self.questions = questions
    }

    /// Try to derive an `AskUserQuestion` from a tool_use's raw `input`
    /// dict. Returns nil if the input doesn't match the expected shape.
    public static func fromToolInput(_ input: Any?) -> AskUserQuestion? {
        guard let dict = input as? [String: Any],
              let rawQuestions = dict["questions"] as? [[String: Any]] else { return nil }
        var parsed: [Question] = []
        for raw in rawQuestions {
            guard let question = raw["question"] as? String,
                  let header = raw["header"] as? String,
                  let rawOptions = raw["options"] as? [[String: Any]] else { continue }
            let multiSelect = (raw["multiSelect"] as? Bool) ?? false
            var options: [Option] = []
            for ro in rawOptions {
                guard let label = ro["label"] as? String else { continue }
                let description = (ro["description"] as? String) ?? ""
                options.append(Option(label: label, description: description))
            }
            guard !options.isEmpty else { continue }
            parsed.append(Question(
                question: question,
                header: header,
                multiSelect: multiSelect,
                options: options
            ))
        }
        guard !parsed.isEmpty else { return nil }
        return AskUserQuestion(questions: parsed)
    }
}

/// v0.5.5: file-edit summary attached to Edit/MultiEdit/Write tool_use
/// `ChatMessage`s so the chat row can render `Edited <basename> +N -M`
/// without re-parsing the raw `input` JSON downstream. Drives the
/// inline disclosure that mirrors Claude Code's CLI rendering.
public struct EditStats: Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable {
        case edit
        case multiEdit
        case write
    }

    public let kind: Kind
    public let filePath: String
    public let additions: Int
    public let deletions: Int

    public init(kind: Kind, filePath: String, additions: Int, deletions: Int) {
        self.kind = kind
        self.filePath = filePath
        self.additions = additions
        self.deletions = deletions
    }

    /// Basename of the file path — what gets shown in the row label so
    /// long path strings don't dominate. Falls back to the full path
    /// when the basename can't be derived.
    public var basename: String {
        let last = (filePath as NSString).lastPathComponent
        return last.isEmpty ? filePath : last
    }

    /// Try to derive an EditStats from a Claude tool_use's raw `input`
    /// dict + the tool's `name`. Returns nil for non-file-edit tools or
    /// when the expected fields are missing.
    public static func fromClaudeInput(_ input: Any?, toolName: String) -> EditStats? {
        guard let dict = input as? [String: Any] else { return nil }
        switch toolName {
        case "Edit":
            guard let path = dict["file_path"] as? String,
                  let oldStr = dict["old_string"] as? String,
                  let newStr = dict["new_string"] as? String else { return nil }
            return EditStats(
                kind: .edit,
                filePath: path,
                additions: lineCount(newStr),
                deletions: lineCount(oldStr)
            )
        case "MultiEdit":
            guard let path = dict["file_path"] as? String,
                  let edits = dict["edits"] as? [[String: Any]] else { return nil }
            var add = 0
            var del = 0
            for e in edits {
                if let oldStr = e["old_string"] as? String { del += lineCount(oldStr) }
                if let newStr = e["new_string"] as? String { add += lineCount(newStr) }
            }
            return EditStats(kind: .multiEdit, filePath: path, additions: add, deletions: del)
        case "Write":
            guard let path = dict["file_path"] as? String,
                  let content = dict["content"] as? String else { return nil }
            // Write replaces (or creates) the file wholesale. Without
            // knowing the prior content at parse time we can't compute
            // deletions; show only additions. Caller's view renders
            // `+N` and omits the `-` half when deletions is 0.
            return EditStats(kind: .write, filePath: path, additions: lineCount(content), deletions: 0)
        default:
            return nil
        }
    }

    private static func lineCount(_ s: String) -> Int {
        if s.isEmpty { return 0 }
        // Count the number of NEWLINE-terminated lines. An empty string
        // yields 0; a single line with no trailing newline yields 1.
        var n = 1
        for c in s where c == "\n" { n += 1 }
        // Trailing newline shouldn't add an extra empty line.
        if s.hasSuffix("\n") { n -= 1 }
        return max(n, 1)
    }
}

/// One `tool_use` paired with its (optional) `tool_result`. The result is
/// `nil` while we're waiting for the tool to return; the view renders a
/// spinner / placeholder until the matching line arrives.
public struct ToolPair: Identifiable, Hashable, Sendable, Codable {
    public let id: String           // tool_use_id, matches across call + result
    public let call: ChatMessage
    public let result: ChatMessage?

    public init(id: String, call: ChatMessage, result: ChatMessage? = nil) {
        self.id = id
        self.call = call
        self.result = result
    }
}

/// One row in the chat thread. Either a plain message (user prose,
/// assistant prose, or meta), or a `toolRun` group that bundles
/// consecutive tool_use + tool_result messages between prose turns.
public enum ChatItem: Identifiable, Hashable, Sendable, Codable {
    case message(ChatMessage)
    case toolRun(id: String, pairs: [ToolPair])

    public var id: String {
        switch self {
        case .message(let m):       return m.id
        case .toolRun(let id, _):   return "run:\(id)"
        }
    }
}

// MARK: - T8/T9 precomputed right-pane state
//
// All three derived arrays below are produced by the StagingParser
// alongside `items` so PlanTrackerPane / SourcesPane / ArtifactsPane can
// read them with zero per-render work.

/// One step extracted from a Plan / numbered-list / "Step N:" prefix in
/// the planText or any assistant message. Carries a precomputed
/// `isComplete` flag (set when a subsequent message references the step
/// — substring match, lowercased, first ~30 chars).
public struct PlanStep: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public let text: String
    public let isComplete: Bool

    public init(id: String, text: String, isComplete: Bool) {
        self.id = id
        self.text = text
        self.isComplete = isComplete
    }
}

/// One todo from a Codex SDK `todo_list` stream event. v0.7.8 model
/// added so the SDK event's structure survives all the way through to
/// the Mac Plan pane + iOS Plan tab + Watch complication — previously
/// the ingestor flattened it to a "Todo list updated, N items" meta
/// chat row which lost the actual content.
///
/// The Codex SDK fires three statuses: pending, in_progress, completed.
/// We keep the raw string instead of an enum so a future Codex SDK
/// release adding a new status (e.g. "blocked") decodes cleanly.
public struct CodexTodoItem: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public let text: String
    public let status: String  // "pending" | "in_progress" | "completed" | future statuses

    public init(id: String, text: String, status: String) {
        self.id = id
        self.text = text
        self.status = status
    }

    public var isCompleted: Bool { status == "completed" }
    public var isInProgress: Bool { status == "in_progress" }
    public var isPending: Bool { status == "pending" }
}

/// One file path or URL the agent referenced (Read/Grep/Glob/WebFetch/etc.).
/// Sortable by `count` for "most-cited" surfacing.
public struct SourceEntry: Identifiable, Hashable, Sendable, Codable {
    public enum Kind: String, Sendable, Codable {
        case file
        case url
    }
    public let id: String       // "f:<label>" or "u:<label>"
    public let kind: Kind
    public let label: String
    /// Absolute path (files) or URL string. For files this may differ
    /// from `label` when the agent wrote a relative path; the renderer
    /// uses `payload` to open in Finder.
    public let payload: String
    public let count: Int

    public init(id: String, kind: Kind, label: String, payload: String, count: Int) {
        self.id = id
        self.kind = kind
        self.label = label
        self.payload = payload
        self.count = count
    }
}

/// One artifact the agent wrote (PDF, image, doc, spreadsheet, etc.).
/// Stored as an absolute path; the renderer derives extension + filename
/// + QuickLook thumbnail on demand.
public struct ArtifactEntry: Identifiable, Hashable, Sendable, Codable {
    public let id: String   // absolute path
    public let path: String
    public let filename: String

    public init(path: String) {
        self.id = path
        self.path = path
        self.filename = (path as NSString).lastPathComponent
    }
}

// MARK: - Sort helpers (extracted from StagingParser for testability)

/// Ordering rank for `ChatMessage.kind` — drives the `(at, kind, id)`
/// sort tiebreak used by the staging parser. The interesting case: on
/// the same timestamp, a `tool_use` MUST sort before its matching
/// `tool_result` so that `ChatItemBuilder.ingest` pairs them correctly.
/// The original implementation relied on `"call:" < "result:"`
/// lexicographic ordering of ids; this is the typed form per the
/// hardening sprint. Lives in Shared so unit tests can verify the
/// invariant across both id-prefix conventions Anthropic might ship.
public enum ChatMessageOrdering {
    public static func kindRank(_ kind: ChatMessage.Kind) -> Int {
        switch kind {
        case .userText:      return 0
        case .assistantText: return 1
        case .toolCall:      return 2
        case .toolResult:    return 3
        case .meta:          return 4
        }
    }

    /// Returns true if `a` should sort BEFORE `b`. Total order:
    /// `(at, kindRank, id)`.
    public static func precedes(_ a: ChatMessage, _ b: ChatMessage) -> Bool {
        if a.at != b.at { return a.at < b.at }
        let ra = kindRank(a.kind)
        let rb = kindRank(b.kind)
        if ra != rb { return ra < rb }
        return a.id < b.id
    }

    /// Extract numbered (`1. foo`) or `Step N: foo` step candidates from
    /// a body string. Returns them in order of first appearance. Used by
    /// the staging parser's plan-step precompute; extracted here so
    /// tests can verify the regex behavior without spinning up the
    /// actor.
    public static func extractStepCandidates(from body: String) -> [String] {
        var out: [String] = []
        for raw in body.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let match = line.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
                let content = String(line[match.upperBound...])
                    .trimmingCharacters(in: .whitespaces)
                if !content.isEmpty { out.append(content) }
                continue
            }
            if let match = line.range(of: #"^Step\s+\d+:?\s+"#,
                                       options: [.regularExpression, .caseInsensitive]) {
                let content = String(line[match.upperBound...])
                    .trimmingCharacters(in: .whitespaces)
                if !content.isEmpty { out.append(content) }
            }
        }
        return out
    }
}

/// Incremental items builder. The staging parser pushes parsed
/// `ChatMessage` values in arrival order; the builder maintains the
/// `items` array such that consecutive tool_use + tool_result messages
/// fold into a single `ChatItem.toolRun`.
///
/// Invariants:
/// - Append-only on the items array (no random-access mutation).
/// - At most one "pending" tool run is in flight at a time. New prose
///   flushes the pending run; new tool messages append to it.
/// - Malformed lines that produced no message are skipped silently
///   (matches today's JSONLTail behavior; CQ3' codex-driven revert).
///
/// This is a value type with no actor isolation; callers (the staging
/// parser actor in `SessionChatStore`) own the synchronization.
public struct ChatItemBuilder: Sendable {
    public private(set) var items: [ChatItem] = []

    /// Pending tool-run cursor. When a tool_use arrives we push a new
    /// pair; when its matching tool_result arrives we fill the result
    /// slot. Anything that isn't a tool message flushes the pending run.
    private var pendingPairs: [String: ToolPair] = [:]
    private var pendingOrder: [String] = []

    public init() {}

    /// Ingest one parsed `ChatMessage`. Returns the delta describing what
    /// changed in `items` so the caller can publish minimal updates.
    /// Currently the delta is informational; views observe `items`
    /// wholesale via the store snapshot.
    @discardableResult
    public mutating func ingest(_ message: ChatMessage) -> Delta {
        switch message.kind {
        case .toolCall:
            // tool_use ids in our pipeline are prefixed with "call:" —
            // strip the prefix so we can pair with the matching result.
            let toolUseId = message.id.hasPrefix("call:")
                ? String(message.id.dropFirst("call:".count))
                : message.id
            // Duplicate tool_use_id within the same pending run would
            // overwrite the prior call (potentially dropping an
            // already-paired result) and duplicate the id in
            // pendingOrder. Keep the first instance; subsequent
            // duplicates are silently dropped — the dedup-by-id contract
            // is owned by the staging actor's seenIds before we get here,
            // so this is defense-in-depth.
            guard pendingPairs[toolUseId] == nil else {
                return .pendingExtended(toolUseId: toolUseId)
            }
            pendingPairs[toolUseId] = ToolPair(id: toolUseId, call: message, result: nil)
            pendingOrder.append(toolUseId)
            return .pendingExtended(toolUseId: toolUseId)
        case .toolResult:
            let toolUseId = message.id.hasPrefix("result:")
                ? String(message.id.dropFirst("result:".count))
                : message.id
            if let existing = pendingPairs[toolUseId] {
                pendingPairs[toolUseId] = ToolPair(
                    id: toolUseId, call: existing.call, result: message
                )
                return .pendingResolved(toolUseId: toolUseId)
            }
            // Orphan tool_result with no matching call — drop. This can
            // happen during the reverse-tail parse before the head fills
            // in earlier tool_use messages; the reconciliation pass will
            // re-ingest in chronological order.
            return .orphanResult(toolUseId: toolUseId)
        case .userText, .assistantText, .meta:
            let flushed = flushPendingInternal()
            items.append(.message(message))
            return flushed.isEmpty
                ? .messageAppended(id: message.id)
                : .flushedThenAppended(flushedRuns: flushed.count, id: message.id)
        }
    }

    /// Explicitly flush any in-flight tool run (used when we hit EOF or
    /// the caller wants to render now). After flush, `pendingPairs` is
    /// empty and any half-formed run is in `items`.
    public mutating func flushPending() {
        _ = flushPendingInternal()
    }

    @discardableResult
    private mutating func flushPendingInternal() -> [String] {
        guard !pendingOrder.isEmpty else { return [] }
        let pairs = pendingOrder.compactMap { pendingPairs[$0] }
        if let firstId = pairs.first?.id {
            items.append(.toolRun(id: firstId, pairs: pairs))
        }
        let flushedIds = pendingOrder
        pendingPairs.removeAll(keepingCapacity: true)
        pendingOrder.removeAll(keepingCapacity: true)
        return flushedIds
    }

    /// Describes what the last `ingest` did to the items array. Useful
    /// for tracing / signpost annotations. Not consumed by the UI today.
    public enum Delta: Equatable, Sendable {
        case pendingExtended(toolUseId: String)
        case pendingResolved(toolUseId: String)
        case orphanResult(toolUseId: String)
        case messageAppended(id: String)
        case flushedThenAppended(flushedRuns: Int, id: String)
    }
}

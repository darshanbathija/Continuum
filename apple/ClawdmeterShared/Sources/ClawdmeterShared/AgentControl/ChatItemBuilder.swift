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

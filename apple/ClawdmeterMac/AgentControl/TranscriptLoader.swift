import Foundation
import ClawdmeterShared

/// One-shot reader that turns a JSONL on disk into a chronological list of
/// `ChatMessage` values for the `/transcript` HTTP endpoint to ship to
/// iOS. Re-uses `ParsedLine.from(json:)` (the same path
/// `SessionChatStore.StagingParser` uses live) so the iOS chat view
/// renders identically to the Mac one — same kinds, same titles, same
/// tool_use/tool_result pairing.
///
/// We tail-read by default: the last `maxMessages` entries chronologically.
/// Cap is enforced AFTER sorting because lines can arrive out of order in
/// long sessions (cache-replay events with old timestamps). 200 messages
/// is enough to cover most chat scrollback while keeping the response
/// responsive even for token-heavy assistant turns.
enum TranscriptLoader {
    struct Window {
        let messages: [ChatMessage]
        let truncated: Bool
        let cursorFound: Bool
    }

    static func load(from url: URL, maxMessages: Int) -> [ChatMessage] {
        loadRecent(from: url, maxMessages: maxMessages).messages
    }

    static func loadRecent(from url: URL, maxMessages: Int) -> Window {
        guard maxMessages > 0 else {
            return Window(messages: [], truncated: false, cursorFound: true)
        }
        guard let fh = try? FileHandle(forReadingFrom: url) else {
            return Window(messages: [], truncated: false, cursorFound: true)
        }
        defer { try? fh.close() }

        guard let fileSize = try? fh.seekToEnd(), fileSize > 0 else {
            return Window(messages: [], truncated: false, cursorFound: true)
        }

        var bytesToRead = min(fileSize, UInt64(256 * 1024))
        var messages: [ChatMessage] = []
        var reachedStart = false

        while true {
            let startOffset = fileSize - bytesToRead
            guard (try? fh.seek(toOffset: startOffset)) != nil,
                  var data = try? fh.readToEnd() else {
                return Window(messages: [], truncated: false, cursorFound: true)
            }

            reachedStart = startOffset == 0
            if !reachedStart {
                if let newline = data.firstIndex(of: 0x0A) {
                    data = Data(data[data.index(after: newline)..<data.endIndex])
                } else {
                    data.removeAll(keepingCapacity: true)
                }
            }

            messages = sortedMessages(from: data)
            if messages.count >= maxMessages || reachedStart {
                break
            }
            bytesToRead = min(fileSize, bytesToRead * 2)
        }

        let window = messages.count > maxMessages
            ? Array(messages.suffix(maxMessages))
            : messages
        return Window(
            messages: window,
            truncated: !reachedStart || messages.count > maxMessages,
            cursorFound: true
        )
    }

    static func loadWindowBefore(from url: URL, beforeId: String, limit: Int) -> Window {
        guard limit > 0 else {
            return Window(messages: [], truncated: false, cursorFound: true)
        }
        // Explicit pagination is user-initiated. Keep initial opens bounded
        // through loadRecent, but when the user deliberately asks for older
        // rows we search the full transcript so the cursor does not disappear
        // after repeated "Load earlier" pages in very long sessions.
        let messages = loadAllForPagination(from: url)
        guard let cutIdx = messages.firstIndex(where: { $0.id == beforeId }) else {
            return Window(messages: [], truncated: false, cursorFound: false)
        }
        let start = max(0, cutIdx - limit)
        return Window(
            messages: Array(messages[start..<cutIdx]),
            truncated: start > 0,
            cursorFound: true
        )
    }

    private static func loadAllForPagination(from url: URL) -> [ChatMessage] {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return []
        }
        return sortedMessages(from: data)
    }

    private static func sortedMessages(from data: Data) -> [ChatMessage] {
        var collected: [ChatMessage] = []
        var seenIds = Set<String>()

        var lineStart = data.startIndex
        while lineStart < data.endIndex {
            let nl = data[lineStart...].firstIndex(of: 0x0A) ?? data.endIndex
            let lineBytes = data[lineStart..<nl]
            lineStart = (nl < data.endIndex) ? data.index(after: nl) : data.endIndex
            guard !lineBytes.isEmpty else { continue }
            guard let json = (try? JSONSerialization.jsonObject(with: lineBytes))
                  as? [String: Any] else { continue }
            guard let parsed = ParsedLine.from(json: json) else { continue }
            for msg in parsed.messages {
                if seenIds.contains(msg.id) { continue }
                seenIds.insert(msg.id)
                collected.append(msg)
            }
        }

        // Sort by (at, kindRank, id) — matches StagingParser's invariant
        // so tool_use lines always sort before their matching tool_result.
        collected.sort { ChatMessageOrdering.precedes($0, $1) }

        return collected
    }
}

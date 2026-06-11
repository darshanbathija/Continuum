import Foundation

public enum TranscriptCollapseMode: String, Codable, Hashable, Sendable {
    case latestAnswerOnly
    case fullTranscript
}

public struct TranscriptProjection: Hashable, Sendable {
    public let mode: TranscriptCollapseMode
    public let turns: [TranscriptTurn]
    public let messageToTurnId: [String: String]
    public let itemToTurnId: [String: String]
    public let anchorByMessageId: [String: TranscriptAnchor]

    public init(
        mode: TranscriptCollapseMode,
        turns: [TranscriptTurn],
        messageToTurnId: [String: String],
        itemToTurnId: [String: String],
        anchorByMessageId: [String: TranscriptAnchor]
    ) {
        self.mode = mode
        self.turns = turns
        self.messageToTurnId = messageToTurnId
        self.itemToTurnId = itemToTurnId
        self.anchorByMessageId = anchorByMessageId
    }

    public var visibleRows: [ChatItem] {
        turns.flatMap(\.visibleItems)
    }

    public var hiddenRows: [ChatItem] {
        turns.flatMap(\.hiddenItems)
    }
}

public struct TranscriptProjectionCacheKey: Equatable, Sendable {
    public let updateCounter: UInt64
    public let mode: TranscriptCollapseMode

    public init(updateCounter: UInt64, mode: TranscriptCollapseMode) {
        self.updateCounter = updateCounter
        self.mode = mode
    }
}

public struct TranscriptTurn: Identifiable, Hashable, Sendable {
    public let id: String
    public let prompt: ChatMessage?
    public let finalAssistant: ChatMessage?
    public let visibleItems: [ChatItem]
    public let hiddenItems: [ChatItem]
    public let expandedItems: [ChatItem]
    public let summary: TranscriptTurnSummary
    public let outputArtifacts: [TranscriptOutputArtifact]
    public let editedFiles: [TranscriptEditedFile]

    public init(
        id: String,
        prompt: ChatMessage?,
        finalAssistant: ChatMessage?,
        visibleItems: [ChatItem],
        hiddenItems: [ChatItem],
        expandedItems: [ChatItem],
        summary: TranscriptTurnSummary,
        outputArtifacts: [TranscriptOutputArtifact],
        editedFiles: [TranscriptEditedFile]
    ) {
        self.id = id
        self.prompt = prompt
        self.finalAssistant = finalAssistant
        self.visibleItems = visibleItems
        self.hiddenItems = hiddenItems
        self.expandedItems = expandedItems
        self.summary = summary
        self.outputArtifacts = outputArtifacts
        self.editedFiles = editedFiles
    }

    public var hasCollapsedContent: Bool {
        !hiddenItems.isEmpty
    }
}

public struct TranscriptTurnSummary: Hashable, Sendable {
    public let startedAt: Date?
    public let endedAt: Date?
    public let durationSeconds: TimeInterval
    public let hiddenMessageCount: Int
    public let toolCallCount: Int

    public init(
        startedAt: Date?,
        endedAt: Date?,
        durationSeconds: TimeInterval,
        hiddenMessageCount: Int,
        toolCallCount: Int
    ) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSeconds = durationSeconds
        self.hiddenMessageCount = hiddenMessageCount
        self.toolCallCount = toolCallCount
    }

    public var thoughtForLabel: String {
        "Thought for \(Self.formatDuration(durationSeconds))"
    }

    public var disclosureLabel: String {
        thoughtForLabel
    }

    public static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m \(secs)s"
        }
        if minutes > 0 {
            return "\(minutes)m \(secs)s"
        }
        return "\(secs)s"
    }
}

public struct TranscriptAnchor: Hashable, Sendable {
    public let turnId: String
    public let itemId: String
    public let messageId: String
    public let runId: String?
    public let pairId: String?
    public let isHidden: Bool

    public init(turnId: String, itemId: String, messageId: String, runId: String?, pairId: String?, isHidden: Bool) {
        self.turnId = turnId
        self.itemId = itemId
        self.messageId = messageId
        self.runId = runId
        self.pairId = pairId
        self.isHidden = isHidden
    }
}

public enum TranscriptArtifactKind: String, Codable, Hashable, Sendable {
    case markdown
    case html
    case image
    case pdf
    case document
    case spreadsheet
    case presentation
    case media
    case archive
    case data
}

public struct TranscriptOutputArtifact: Identifiable, Codable, Hashable, Sendable {
    public let kind: TranscriptArtifactKind
    public let path: String
    public let sourceToolName: String?

    public var id: String { "\(kind.rawValue):\(path)" }
    public var filename: String {
        let last = (path as NSString).lastPathComponent
        return last.isEmpty ? path : last
    }

    public init(kind: TranscriptArtifactKind, path: String, sourceToolName: String? = nil) {
        self.kind = kind
        self.path = path
        self.sourceToolName = sourceToolName
    }
}

public enum TranscriptArtifactClassifier {
    public static let markdownExtensions: Set<String> = ["md", "markdown", "mdown"]
    public static let htmlExtensions: Set<String> = ["html", "htm"]
    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "svg", "webp", "tiff", "heic"]
    public static let pdfExtensions: Set<String> = ["pdf"]
    public static let documentExtensions: Set<String> = ["doc", "docx", "rtf", "txt"]
    public static let spreadsheetExtensions: Set<String> = ["xls", "xlsx", "numbers"]
    public static let presentationExtensions: Set<String> = ["ppt", "pptx", "key"]
    public static let mediaExtensions: Set<String> = ["mp4", "mov", "mp3", "wav"]
    public static let archiveExtensions: Set<String> = ["zip", "tar", "gz", "tgz"]
    public static let dataExtensions: Set<String> = ["csv", "tsv", "json"]

    public static var artifactExtensions: Set<String> {
        markdownExtensions
            .union(htmlExtensions)
            .union(imageExtensions)
            .union(pdfExtensions)
            .union(documentExtensions)
            .union(spreadsheetExtensions)
            .union(presentationExtensions)
            .union(mediaExtensions)
            .union(archiveExtensions)
            .union(dataExtensions)
    }

    public static func kind(forPath path: String) -> TranscriptArtifactKind? {
        let ext = (path as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        if markdownExtensions.contains(ext) { return .markdown }
        if htmlExtensions.contains(ext) { return .html }
        if imageExtensions.contains(ext) { return .image }
        if pdfExtensions.contains(ext) { return .pdf }
        if documentExtensions.contains(ext) { return .document }
        if spreadsheetExtensions.contains(ext) { return .spreadsheet }
        if presentationExtensions.contains(ext) { return .presentation }
        if mediaExtensions.contains(ext) { return .media }
        if archiveExtensions.contains(ext) { return .archive }
        if dataExtensions.contains(ext) { return .data }
        return nil
    }

    public static func isMarkdownPath(_ path: String) -> Bool {
        kind(forPath: path) == .markdown
    }

    public static func isArtifactPath(_ path: String) -> Bool {
        kind(forPath: path) != nil
    }

    public static func pathCandidates(in text: String) -> [String] {
        let extensions = artifactExtensions.sorted().joined(separator: "|")
        let pattern = #"(?i)(?:^|[\s"'`(])((?:(?:~|/|\.{1,2}/|[A-Za-z0-9_.-]+/)[^\s"'`()<>]+|[A-Za-z0-9_.-]+)\.(?:\#(extensions)))(?=$|[\s"'`),.])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let pathRange = Range(match.range(at: 1), in: text)
            else { return nil }
            return String(text[pathRange])
        }
    }
}

public struct TranscriptEditedFile: Identifiable, Codable, Hashable, Sendable {
    public let filePath: String
    public let additions: Int
    public let deletions: Int
    public let sourceToolName: String?

    public var id: String { filePath }
    public var basename: String {
        let last = (filePath as NSString).lastPathComponent
        return last.isEmpty ? filePath : last
    }

    public init(filePath: String, additions: Int, deletions: Int, sourceToolName: String? = nil) {
        self.filePath = filePath
        self.additions = additions
        self.deletions = deletions
        self.sourceToolName = sourceToolName
    }

    public static func from(_ message: ChatMessage) -> [TranscriptEditedFile] {
        guard message.kind == .toolCall else { return [] }
        if let stats = message.editStats {
            return [
                TranscriptEditedFile(
                    filePath: stats.filePath,
                    additions: stats.additions,
                    deletions: stats.deletions,
                    sourceToolName: message.title
                )
            ]
        }
        guard let diff = message.editDiff else { return [] }
        if diff.kind == .applyPatch, let patch = diff.preview {
            let parsed = TranscriptPatchEditedFileParser.files(fromPatch: patch, sourceToolName: message.title)
            if !parsed.isEmpty { return parsed }
        }
        guard let path = diff.filePath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else { return [] }
        return [
            TranscriptEditedFile(
                filePath: path,
                additions: diff.additions,
                deletions: diff.deletions,
                sourceToolName: message.title
            )
        ]
    }
}

public enum TranscriptPatchEditedFileParser {
    private struct MutableFile {
        var path: String
        var additions: Int = 0
        var deletions: Int = 0
    }

    public static func files(fromPatch patch: String, sourceToolName: String? = nil) -> [TranscriptEditedFile] {
        var current: MutableFile?
        var out: [TranscriptEditedFile] = []

        func flush() {
            guard let file = current else { return }
            out.append(TranscriptEditedFile(
                filePath: file.path,
                additions: file.additions,
                deletions: file.deletions,
                sourceToolName: sourceToolName
            ))
            current = nil
        }

        func start(_ path: String) {
            let clean = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, clean != "/dev/null" else { return }
            if current?.path != clean {
                flush()
                current = MutableFile(path: clean)
            }
        }

        for rawLine in patch.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let path = stripPrefix("*** Update File: ", from: line)
                ?? stripPrefix("*** Add File: ", from: line)
                ?? stripPrefix("*** Delete File: ", from: line)
                ?? stripPrefix("*** Move to: ", from: line) {
                start(path)
                continue
            }
            if line.hasPrefix("diff --git ") {
                if let path = diffGitPath(from: line) {
                    start(path)
                }
                continue
            }
            if let path = diffPath(from: line, prefix: "+++ b/") {
                start(path)
                continue
            }
            if current == nil, let path = diffPath(from: line, prefix: "--- b/") {
                start(path)
                continue
            }
            if rawLine.hasPrefix("+"), !rawLine.hasPrefix("+++") {
                if current == nil { current = MutableFile(path: "(unknown)") }
                current?.additions += 1
            } else if rawLine.hasPrefix("-"), !rawLine.hasPrefix("---") {
                if current == nil { current = MutableFile(path: "(unknown)") }
                current?.deletions += 1
            }
        }
        flush()

        var merged: [String: TranscriptEditedFile] = [:]
        var order: [String] = []
        for file in out where file.filePath != "(unknown)" {
            if let existing = merged[file.filePath] {
                merged[file.filePath] = TranscriptEditedFile(
                    filePath: file.filePath,
                    additions: existing.additions + file.additions,
                    deletions: existing.deletions + file.deletions,
                    sourceToolName: existing.sourceToolName ?? file.sourceToolName
                )
            } else {
                merged[file.filePath] = file
                order.append(file.filePath)
            }
        }
        return order.compactMap { merged[$0] }
    }

    private static func stripPrefix(_ prefix: String, from line: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    private static func diffPath(from line: String, prefix: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        let path = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        return path == "/dev/null" ? nil : path
    }

    private static func diffGitPath(from line: String) -> String? {
        let parts = line.split(separator: " ").map(String.init)
        guard parts.count >= 4 else { return nil }
        let bPath = parts[3]
        guard bPath.hasPrefix("b/") else { return nil }
        return String(bPath.dropFirst(2))
    }
}

public enum PromptBoundary {
    public static func isRealPrompt(_ message: ChatMessage, previous: ChatMessage?) -> Bool {
        message.kind == .userText && previous?.kind != .toolResult
    }
}

public enum TranscriptTurnProjector {
    public static func project(
        messages: [ChatMessage],
        mode: TranscriptCollapseMode = .latestAnswerOnly,
        now: Date = Date()
    ) -> TranscriptProjection {
        guard !messages.isEmpty else {
            return TranscriptProjection(mode: mode, turns: [], messageToTurnId: [:], itemToTurnId: [:], anchorByMessageId: [:])
        }

        var segments: [[ChatMessage]] = []
        var current: [ChatMessage] = []
        var previous: ChatMessage?
        for message in messages {
            let startsRealPrompt = PromptBoundary.isRealPrompt(message, previous: previous)
                || (message.kind == .userText && !current.contains(where: { $0.kind == .userText }))
            if startsRealPrompt, !current.isEmpty {
                segments.append(current)
                current = [message]
            } else {
                current.append(message)
            }
            previous = message
        }
        if !current.isEmpty {
            segments.append(current)
        }

        var turns: [TranscriptTurn] = []
        var messageToTurnId: [String: String] = [:]
        var itemToTurnId: [String: String] = [:]
        var anchorByMessageId: [String: TranscriptAnchor] = [:]

        for (index, segment) in segments.enumerated() {
            let turn = makeTurn(messages: segment, index: index, mode: mode, now: now)
            turns.append(turn)
            for message in segment {
                messageToTurnId[message.id] = turn.id
            }
            for item in turn.expandedItems {
                itemToTurnId[item.id] = turn.id
                mapAnchors(for: item, turn: turn, hiddenItems: turn.hiddenItems, into: &anchorByMessageId)
            }
        }

        return TranscriptProjection(
            mode: mode,
            turns: turns,
            messageToTurnId: messageToTurnId,
            itemToTurnId: itemToTurnId,
            anchorByMessageId: anchorByMessageId
        )
    }

    public static func project(
        items: [ChatItem],
        mode: TranscriptCollapseMode = .latestAnswerOnly,
        now: Date = Date()
    ) -> TranscriptProjection {
        project(messages: flatten(items), mode: mode, now: now)
    }

    public static func project(
        items: [ChatItem],
        messages: [ChatMessage],
        mode: TranscriptCollapseMode = .latestAnswerOnly,
        now: Date = Date()
    ) -> TranscriptProjection {
        // The canonical path is message-based so paginated archived transcripts
        // can preserve orphan tool rows. Callers still pass prebuilt items as a
        // signal that the source already has grouped rows; v1 keeps the shared
        // behavior lossless by deriving from messages.
        _ = items
        return project(messages: messages, mode: mode, now: now)
    }

    private static func makeTurn(
        messages: [ChatMessage],
        index: Int,
        mode: TranscriptCollapseMode,
        now: Date
    ) -> TranscriptTurn {
        let items = buildLosslessItems(from: messages)
        let prompt = messages.first(where: { PromptBoundary.isRealPrompt($0, previous: previousMessage(before: $0, in: messages)) })
            ?? messages.first(where: { $0.kind == .userText })
        let finalAssistant = messages.last(where: { $0.kind == .assistantText })
        let turnId = prompt.map { "turn:\($0.id)" } ?? "turn:leading-\(index)"

        let visibleItems: [ChatItem]
        let hiddenItems: [ChatItem]
        if mode == .fullTranscript || prompt == nil || finalAssistant == nil {
            visibleItems = items
            hiddenItems = []
        } else {
            let visibleMessageIds = Set([prompt?.id, finalAssistant?.id].compactMap { $0 })
            visibleItems = items.compactMap { item in
                switch item {
                case .message(let message):
                    return visibleMessageIds.contains(message.id) ? item : nil
                case .toolRun:
                    return nil
                }
            }
            hiddenItems = items.compactMap { item in
                switch item {
                case .message(let message):
                    return visibleMessageIds.contains(message.id) ? nil : item
                case .toolRun:
                    return item
                }
            }
        }

        let hiddenMessages = flatten(hiddenItems)
        let start = prompt?.at ?? messages.first?.at
        let end = messages.last?.at ?? start
        let durationEnd = end ?? now
        let summary = TranscriptTurnSummary(
            startedAt: start,
            endedAt: end,
            durationSeconds: max(0, durationEnd.timeIntervalSince(start ?? durationEnd)),
            hiddenMessageCount: hiddenMessages.count,
            toolCallCount: messages.filter { $0.kind == .toolCall }.count
        )

        return TranscriptTurn(
            id: turnId,
            prompt: prompt,
            finalAssistant: finalAssistant,
            visibleItems: visibleItems,
            hiddenItems: hiddenItems,
            expandedItems: items,
            summary: summary,
            outputArtifacts: outputArtifacts(from: messages),
            editedFiles: editedFiles(from: messages)
        )
    }

    private static func previousMessage(before message: ChatMessage, in messages: [ChatMessage]) -> ChatMessage? {
        guard let idx = messages.firstIndex(where: { $0.id == message.id }), idx > 0 else { return nil }
        return messages[idx - 1]
    }

    private static func buildLosslessItems(from messages: [ChatMessage]) -> [ChatItem] {
        var items: [ChatItem] = []
        var pendingPairs: [String: ToolPair] = [:]
        var pendingOrder: [String] = []

        func flushPending() {
            guard !pendingOrder.isEmpty else { return }
            let pairs = pendingOrder.compactMap { pendingPairs[$0] }
            if let first = pairs.first {
                items.append(.toolRun(id: first.id, pairs: pairs))
            }
            pendingPairs.removeAll(keepingCapacity: true)
            pendingOrder.removeAll(keepingCapacity: true)
        }

        for message in messages {
            switch message.kind {
            case .toolCall:
                let id = unprefixed(message.id, prefix: "call:")
                if pendingPairs[id] == nil {
                    pendingPairs[id] = ToolPair(id: id, call: message, result: nil)
                    pendingOrder.append(id)
                }
            case .toolResult:
                let id = unprefixed(message.id, prefix: "result:")
                if let existing = pendingPairs[id] {
                    pendingPairs[id] = ToolPair(id: id, call: existing.call, result: message)
                } else {
                    flushPending()
                    items.append(.message(message))
                }
            case .userText, .assistantText, .meta:
                flushPending()
                items.append(.message(message))
            }
        }
        flushPending()
        return items
    }

    private static func unprefixed(_ id: String, prefix: String) -> String {
        id.hasPrefix(prefix) ? String(id.dropFirst(prefix.count)) : id
    }

    private static func mapAnchors(
        for item: ChatItem,
        turn: TranscriptTurn,
        hiddenItems: [ChatItem],
        into anchors: inout [String: TranscriptAnchor]
    ) {
        let hiddenItemIds = Set(hiddenItems.map(\.id))
        switch item {
        case .message(let message):
            anchors[message.id] = TranscriptAnchor(
                turnId: turn.id,
                itemId: message.id,
                messageId: message.id,
                runId: nil,
                pairId: nil,
                isHidden: hiddenItemIds.contains(item.id)
            )
        case .toolRun(let runId, let pairs):
            for pair in pairs {
                let anchorId = "pair:\(pair.id)"
                anchors[pair.call.id] = TranscriptAnchor(
                    turnId: turn.id,
                    itemId: anchorId,
                    messageId: pair.call.id,
                    runId: runId,
                    pairId: pair.id,
                    isHidden: hiddenItemIds.contains(item.id)
                )
                if let result = pair.result {
                    anchors[result.id] = TranscriptAnchor(
                        turnId: turn.id,
                        itemId: anchorId,
                        messageId: result.id,
                        runId: runId,
                        pairId: pair.id,
                        isHidden: hiddenItemIds.contains(item.id)
                    )
                }
            }
        }
    }

    private static func flatten(_ items: [ChatItem]) -> [ChatMessage] {
        var out: [ChatMessage] = []
        for item in items {
            switch item {
            case .message(let message):
                out.append(message)
            case .toolRun(_, let pairs):
                for pair in pairs {
                    out.append(pair.call)
                    if let result = pair.result {
                        out.append(result)
                    }
                }
            }
        }
        return out
    }

    private static func outputArtifacts(from messages: [ChatMessage]) -> [TranscriptOutputArtifact] {
        var seen: Set<String> = []
        var out: [TranscriptOutputArtifact] = []
        for message in messages {
            for artifact in message.generatedArtifacts {
                guard artifact.kind == .markdownDocument else { continue }
                appendArtifact(path: artifact.path, sourceToolName: artifact.sourceToolName ?? message.title, seen: &seen, out: &out)
            }
            let text = [message.body, message.detail].compactMap { $0 }.joined(separator: "\n")
            for path in TranscriptArtifactClassifier.pathCandidates(in: text) {
                appendArtifact(path: path, sourceToolName: message.title, seen: &seen, out: &out)
            }
        }
        return out
    }

    private static func appendArtifact(
        path: String,
        sourceToolName: String?,
        seen: inout Set<String>,
        out: inout [TranscriptOutputArtifact]
    ) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let kind = TranscriptArtifactClassifier.kind(forPath: trimmed) else { return }
        let key = "\(kind.rawValue):\(trimmed)"
        guard !seen.contains(key) else { return }
        seen.insert(key)
        out.append(TranscriptOutputArtifact(kind: kind, path: trimmed, sourceToolName: sourceToolName))
    }

    private static func editedFiles(from messages: [ChatMessage]) -> [TranscriptEditedFile] {
        var order: [String] = []
        var merged: [String: TranscriptEditedFile] = [:]
        for message in messages {
            for file in TranscriptEditedFile.from(message) {
                if let existing = merged[file.filePath] {
                    merged[file.filePath] = TranscriptEditedFile(
                        filePath: file.filePath,
                        additions: existing.additions + file.additions,
                        deletions: existing.deletions + file.deletions,
                        sourceToolName: existing.sourceToolName ?? file.sourceToolName
                    )
                } else {
                    merged[file.filePath] = file
                    order.append(file.filePath)
                }
            }
        }
        return order.compactMap { merged[$0] }
    }
}

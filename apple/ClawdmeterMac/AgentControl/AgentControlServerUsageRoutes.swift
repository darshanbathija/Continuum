import Foundation
import Network
import ClawdmeterShared

extension AgentControlServer {
    /// Live UsageData snapshot for paired clients.
    func handleGetUsage(connection: NWConnection) {
        var dict: [String: UsageData] = [:]
        if let c = claudeModel?.usage { dict["claude"] = c }
        if let x = codexModel?.usage { dict["codex"] = x }
        if let g = geminiModel?.usage { dict["gemini"] = g }
        if let cursor = cursorModel?.usage { dict["cursor"] = cursor }
        if let grok = grokModel?.usage { dict["grok"] = grok }
        let payload = UsageEnvelope(
            claude: claudeModel?.usage,
            codex: codexModel?.usage,
            usage: dict,
            lastChecked: Date()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let body = try? encoder.encode(payload) {
            sendResponse(.ok(contentType: "application/json", body: body), on: connection)
        } else {
            sendResponse(.internalError, on: connection)
        }
    }

    /// Historical analytics snapshot used by iOS/watch paired clients.
    func handleGetAnalytics(connection: NWConnection) {
        let snapshot = usageHistory?.snapshot ?? UsageHistorySnapshot.empty
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let body = try? encoder.encode(snapshot) {
            sendResponse(.ok(contentType: "application/json", body: body), on: connection)
        } else {
            sendResponse(.internalError, on: connection)
        }
    }

    /// Parse a JSONL on the Mac and return chat messages as JSON.
    func handleGetTranscript(path queryPath: String, connection: NWConnection) {
        guard let queryStart = queryPath.firstIndex(of: "?") else {
            sendResponse(.notFound, on: connection)
            return
        }
        let query = String(queryPath[queryPath.index(after: queryStart)...])
        var jsonlPath: String?
        var maxMessages = 200
        var beforeId: String?
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            let value = kv[1].removingPercentEncoding ?? kv[1]
            switch kv[0] {
            case "path": jsonlPath = value
            case "limit": maxMessages = max(1, min(200, Int(value) ?? 200))
            case "beforeId": beforeId = value.isEmpty ? nil : value
            default: break
            }
        }
        guard let jsonlPath else {
            sendResponse(.notFound, on: connection)
            return
        }
        let home = ClawdmeterRealHome.path()
        let allowedPrefixes = [
            home + "/.claude/projects/",
            home + "/.codex/sessions/",
        ]
        guard allowedPrefixes.contains(where: { jsonlPath.hasPrefix($0) }) else {
            serverLogger.warning("transcript: refusing read outside allow-list - \(jsonlPath, privacy: .public)")
            sendResponse(.unauthorized, on: connection)
            return
        }
        let url = URL(fileURLWithPath: jsonlPath)
        let messages: [ChatMessage]
        let truncated: Bool
        if let beforeId {
            let page = TranscriptLoader.loadWindowBefore(
                from: url,
                beforeId: beforeId,
                limit: maxMessages
            )
            if page.cursorFound {
                messages = page.messages
                truncated = page.truncated
            } else {
                messages = []
                truncated = false
            }
        } else {
            if let store = chatStoreRegistry.snapshotStore(forJSONLPath: url),
               !store.snapshot.messages.isEmpty {
                messages = store.snapshot.messages.suffix(maxMessages).map { $0 }
                truncated = store.hasOlderHistory || store.snapshot.messages.count > maxMessages
            } else {
                let page = TranscriptLoader.loadRecent(from: url, maxMessages: maxMessages)
                messages = page.messages
                truncated = page.truncated
            }
        }
        let envelope = TranscriptEnvelope(
            path: jsonlPath,
            messages: messages,
            truncated: truncated
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let body = try? encoder.encode(envelope) {
            sendResponse(.ok(contentType: "application/json", body: body), on: connection)
        } else {
            sendResponse(.internalError, on: connection)
        }
    }
}

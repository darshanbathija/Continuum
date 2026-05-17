import Foundation

/// Extracts the CLI-side session/rollout id from the header of a JSONL
/// session file. The CLI id is what `claude --resume <id>` and
/// `codex resume <id>` expect — NOT the Clawdmeter `AgentSession.id` UUID.
///
/// File shapes observed (2026-05-18, claude 2.1.138 / codex 0.128):
/// - Claude: every line carries `"sessionId": "<uuid>"` (camelCase).
/// - Codex: first line `{"type": "session_meta", "payload": {"id": "<uuid>", ...}}`.
public enum JSONLSessionId {

    public enum Provider {
        case claude
        case codex
    }

    /// Read the first ~16KB of the JSONL and pull the CLI session id.
    /// Returns nil if the file is missing, unreadable, or the id key is
    /// absent. Caller (Wave A "Continue here") falls back to read-only
    /// when nil is returned.
    public static func extract(from fileURL: URL, provider: Provider) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return nil
        }
        defer { try? handle.close() }
        // 16KB is enough for the largest known Codex session_meta line
        // (which can carry a multi-KB base_instructions blob).
        let data = handle.readData(ofLength: 16 * 1024)
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        // Scan line-by-line so we don't depend on the whole prefix being
        // valid JSON (Codex sometimes prepends a stray newline).
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            guard let lineData = line.data(using: .utf8) else { continue }
            guard let any = try? JSONSerialization.jsonObject(with: lineData) else { continue }
            guard let obj = any as? [String: Any] else { continue }
            switch provider {
            case .claude:
                if let id = obj["sessionId"] as? String, !id.isEmpty {
                    return id
                }
            case .codex:
                // First useful line is type=session_meta with payload.id.
                if let type = obj["type"] as? String, type == "session_meta",
                   let payload = obj["payload"] as? [String: Any],
                   let id = payload["id"] as? String, !id.isEmpty {
                    return id
                }
            }
        }
        return nil
    }
}

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

    /// Read the JSONL header in chunks until a CLI session id is found or
    /// the size cap is hit. Returns nil if the file is missing, unreadable,
    /// or no usable id is encountered in the first `maxBytes`.
    ///
    /// v0.5.0 robustness pass — was originally a single 64KB read which
    /// would lose to:
    ///   * actively-written files where the kernel hadn't flushed the
    ///     write that contains the first sessionId-bearing line yet
    ///     (`handle.readData` returns short data, the partial last line
    ///     in that chunk fails JSON parse, and no complete line ever has
    ///     the field)
    ///   * Codex variants where the session_meta line sits behind a
    ///     larger header than the typical ~5KB
    ///   * exotic JSONL shapes that don't carry the field in early lines
    /// The new loop reads 64KB at a time up to `maxBytes` (default 1MB).
    /// Empty `readData` (EOF or transient short read) breaks the loop;
    /// any complete line containing the field returns immediately.
    public static func extract(
        from fileURL: URL,
        provider: Provider,
        maxBytes: Int = 1 * 1024 * 1024
    ) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return nil
        }
        defer { try? handle.close() }
        var buffer = Data()
        let chunkSize = 64 * 1024
        while buffer.count < maxBytes {
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }
            buffer.append(chunk)
            // Scan only COMPLETE lines so we don't repeatedly fail-parse
            // the partial trailing line as the buffer grows. Find the
            // last newline; lines up to that point are complete.
            guard let lastNewlineIdx = buffer.lastIndex(of: 0x0A) else { continue }
            let complete = buffer.prefix(through: lastNewlineIdx)
            if let id = scan(complete: complete, provider: provider) {
                return id
            }
        }
        // Final scan covers the case where the file is smaller than one
        // chunk and has no trailing newline (a single line with the
        // header). Without this the loop above never gets a newline to
        // bound the scan window and the file's only line is never tried.
        return scan(complete: buffer, provider: provider)
    }

    private static func scan(complete: Data, provider: Provider) -> String? {
        guard let text = String(data: complete, encoding: .utf8) else { return nil }
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

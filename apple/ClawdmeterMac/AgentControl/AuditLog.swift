import Foundation
import CryptoKit
import OSLog

private let auditLogger = Logger(subsystem: "com.clawdmeter.mac", category: "AuditLog")

/// Append-only audit log for sensitive daemon operations: prompt sends,
/// model swaps, autopilot toggles. Stored as JSONL under
/// `~/.clawdmeter/audit/<event-type>.jsonl`.
///
/// Sessions v2 T13. Hash-only by default for privacy; users can opt into
/// plaintext via UserDefaults `clawdmeter.audit.includePlaintext`.
/// Rotates files at 1MB or 7 days, whichever first (T31).
public actor AuditLog {
    public static let shared = AuditLog()

    private let rootDir: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".clawdmeter/audit", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let rotationByteLimit = 1_000_000        // 1MB
    private static let rotationAgeLimit: TimeInterval = 7 * 24 * 60 * 60  // 7 days

    public init() {}

    /// Whether the user has opted into plaintext logging. Default: false
    /// (hash-only). Settings → Privacy → "Audit log: include plaintext".
    private var includePlaintext: Bool {
        UserDefaults.standard.bool(forKey: "clawdmeter.audit.includePlaintext")
    }

    /// Record a prompt-send event. `text` is hashed by default; plaintext
    /// recorded only when the user opted in.
    public func recordSend(sessionId: UUID, sourcePeer: String, text: String) {
        var entry: [String: Any] = [
            "at": ISO8601DateFormatter().string(from: Date()),
            "kind": "send",
            "sessionId": sessionId.uuidString,
            "sourcePeer": sourcePeer,
            "textHash": sha256(text),
            "textBytes": text.utf8.count,
        ]
        if includePlaintext {
            entry["text"] = text
        }
        append(entry: entry, kind: "sends")
    }

    public func recordSwap(sessionId: UUID, sourcePeer: String, from oldModel: String?, to newModel: String, effort: String?) {
        let entry: [String: Any] = [
            "at": ISO8601DateFormatter().string(from: Date()),
            "kind": "swap",
            "sessionId": sessionId.uuidString,
            "sourcePeer": sourcePeer,
            "oldModel": oldModel ?? "(default)",
            "newModel": newModel,
            "effort": effort ?? "(unchanged)",
        ]
        append(entry: entry, kind: "swaps")
    }

    public func recordAutopilotToggle(sessionId: UUID, sourcePeer: String, enabled: Bool, repoKey: String) {
        let entry: [String: Any] = [
            "at": ISO8601DateFormatter().string(from: Date()),
            "kind": "autopilot",
            "sessionId": sessionId.uuidString,
            "sourcePeer": sourcePeer,
            "enabled": enabled,
            "repoKey": repoKey,
        ]
        append(entry: entry, kind: "autopilot")
    }

    /// Read recent entries from the given log kind. Used by Settings →
    /// Diagnostics → Session Event Timeline (T17).
    public func recentEntries(kind: String, limit: Int = 200) -> [String] {
        let url = rootDir.appendingPathComponent("\(kind).jsonl")
        guard let data = try? Data(contentsOf: url) else { return [] }
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(separator: "\n").map(String.init)
        return Array(lines.suffix(limit))
    }

    // MARK: - Private

    private func append(entry: [String: Any], kind: String) {
        let url = rootDir.appendingPathComponent("\(kind).jsonl")
        rotateIfNeeded(at: url)
        guard let data = try? JSONSerialization.data(withJSONObject: entry) else { return }
        var line = data
        line.append(contentsOf: [0x0a])  // newline
        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(line)
                try? handle.close()
            }
        } else {
            try? line.write(to: url, options: [.atomic])
        }
    }

    private func rotateIfNeeded(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return }
        let size = (attrs[.size] as? Int) ?? 0
        let modifiedAt = (attrs[.modificationDate] as? Date) ?? Date()
        let age = Date().timeIntervalSince(modifiedAt)
        if size > Self.rotationByteLimit || age > Self.rotationAgeLimit {
            let stamp = ISO8601DateFormatter().string(from: modifiedAt).replacingOccurrences(of: ":", with: "-")
            let rotated = url.deletingPathExtension()
                .appendingPathExtension("\(stamp).jsonl")
            try? FileManager.default.moveItem(at: url, to: rotated)
            auditLogger.debug("rotated \(url.lastPathComponent, privacy: .public) → \(rotated.lastPathComponent, privacy: .public)")
        }
    }

    private func sha256(_ s: String) -> String {
        let digest = SHA256.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

import Foundation
import ClawdmeterShared
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
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            // Owner-only — keeps peer IPs + repo paths private on a
            // multi-user Mac. macOS's default umask is 0o022 (others
            // can read), and the audit JSONL contains identifying
            // metadata even when prompt text is hashed.
            attributes: [.posixPermissions: 0o700]
        )
        // The directory may already exist from a prior run on default
        // umask. Tighten its mode unconditionally.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: dir.path
        )
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

    public func recordBlockedPrompt(sessionId: UUID, sourcePeer: String, text: String, origin: ProviderPromptOrigin, reason: String) {
        var entry: [String: Any] = [
            "at": ISO8601DateFormatter().string(from: Date()),
            "kind": "blocked-prompt",
            "sessionId": sessionId.uuidString,
            "sourcePeer": sourcePeer,
            "origin": origin.rawValue,
            "reason": reason,
            "textHash": sha256(text),
            "textBytes": text.utf8.count,
        ]
        if includePlaintext {
            entry["text"] = text
        }
        append(entry: entry, kind: "sends")
    }

    /// Model swap — distinct from effort/mode/plan-approve. Use the
    /// dedicated `recordEffortChange` / `recordModeChange` /
    /// `recordPlanApprove` methods for those event kinds so the swaps
    /// stream stays parseable by event-kind discriminator.
    public func recordSwap(sessionId: UUID, sourcePeer: String, from oldModel: String?, to newModel: String, effort: String?) {
        let entry: [String: Any] = [
            "at": ISO8601DateFormatter().string(from: Date()),
            "kind": "swap-model",
            "sessionId": sessionId.uuidString,
            "sourcePeer": sourcePeer,
            "oldModel": oldModel ?? "(default)",
            "newModel": newModel,
            "effort": effort ?? "(unchanged)",
        ]
        append(entry: entry, kind: "swaps")
    }

    public func recordEffortChange(
        sessionId: UUID, sourcePeer: String, model: String?, effort: String
    ) {
        let entry: [String: Any] = [
            "at": ISO8601DateFormatter().string(from: Date()),
            "kind": "swap-effort",
            "sessionId": sessionId.uuidString,
            "sourcePeer": sourcePeer,
            "model": model ?? "(default)",
            "effort": effort,
        ]
        append(entry: entry, kind: "swaps")
    }

    public func recordModeChange(
        sessionId: UUID, sourcePeer: String, mode: String, planMode: Bool?
    ) {
        var entry: [String: Any] = [
            "at": ISO8601DateFormatter().string(from: Date()),
            "kind": "swap-mode",
            "sessionId": sessionId.uuidString,
            "sourcePeer": sourcePeer,
            "mode": mode,
        ]
        if let planMode {
            entry["planMode"] = planMode
        }
        append(entry: entry, kind: "swaps")
    }

    public func recordPlanApprove(
        sessionId: UUID, sourcePeer: String, agent: String
    ) {
        let entry: [String: Any] = [
            "at": ISO8601DateFormatter().string(from: Date()),
            "kind": "plan-approve",
            "sessionId": sessionId.uuidString,
            "sourcePeer": sourcePeer,
            "agent": agent,
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

    /// v16 Code V2 mobile outbox: every write request that carries an
    /// idempotency key gets a hash-only audit row here. The outbox
    /// replays the last 256 rows of this file on startup so a daemon
    /// restart still dedups in-flight retries from iOS.
    ///
    /// `payloadHash` is the SHA-256 of the request body so we can spot
    /// a client that's reusing the same key with different payloads
    /// (which would be a client bug, not a replay).
    public func recordMobileCommand(
        idempotencyKey: String,
        kind: String,
        sessionId: UUID?,
        sourcePeer: String,
        status: String,
        payloadHash: String,
        serverReceiptId: String
    ) {
        var entry: [String: Any] = [
            "at": ISO8601DateFormatter().string(from: Date()),
            "kind": "mobile-command",
            "command": kind,
            "idempotencyKey": idempotencyKey,
            "sourcePeer": sourcePeer,
            "status": status,
            "payloadHash": payloadHash,
            "serverReceiptId": serverReceiptId,
        ]
        if let sessionId { entry["sessionId"] = sessionId.uuidString }
        append(entry: entry, kind: "mobile-commands")
    }

    /// v0.7.7: record a sidecar ask_user(...) decision. Source is
    /// `mac` / `ios` / `timeout` so the diagnostics view shows which
    /// surface won the cross-surface race (or that neither did).
    public func recordSidecarAsk(promptUUID: UUID, decision: String, source: String) {
        let entry: [String: Any] = [
            "at": ISO8601DateFormatter().string(from: Date()),
            "kind": "sidecar-ask",
            "promptUUID": promptUUID.uuidString,
            "decision": decision,
            "source": source,
        ]
        append(entry: entry, kind: "sidecar-ask")
    }

    /// Read recent entries from the given log kind. Used by Settings →
    /// Diagnostics → Session Event Timeline (T17).
    ///
    /// **Codex R5 #2**: also walks the most-recent rotated archive file
    /// (`<kind>.<stamp>.jsonl`) when the current file alone doesn't hit
    /// `limit`. Without this, restart replay via
    /// `MobileCommandOutbox.replayFromAuditLog` would miss receipts
    /// that rotated between the original request and the restart —
    /// inside the outbox's claimed 24h recovery window.
    public func recentEntries(kind: String, limit: Int = 200) -> [String] {
        let current = rootDir.appendingPathComponent("\(kind).jsonl")
        var lines: [String] = []
        if let data = try? Data(contentsOf: current) {
            let text = String(decoding: data, as: UTF8.self)
            lines = text.split(separator: "\n").map(String.init)
        }
        if lines.count < limit {
            // Pull the most-recent rotated archive for this kind too.
            // Archives are named `<kind>.<iso8601>.jsonl`; we sort by
            // modification time descending to find the newest.
            if let contents = try? FileManager.default.contentsOfDirectory(
                at: rootDir,
                includingPropertiesForKeys: [.contentModificationDateKey]
            ) {
                let prefix = "\(kind)."
                let archives = contents
                    .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "jsonl" && $0.lastPathComponent != "\(kind).jsonl" }
                    .compactMap { url -> (URL, Date)? in
                        guard let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                        else { return nil }
                        return (url, mtime)
                    }
                    .sorted { $0.1 > $1.1 }
                for (archiveURL, _) in archives {
                    guard let data = try? Data(contentsOf: archiveURL) else { continue }
                    let text = String(decoding: data, as: UTF8.self)
                    let archived = text.split(separator: "\n").map(String.init)
                    lines = archived + lines
                    if lines.count >= limit { break }
                }
            }
        }
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
            // Owner-only — tighten on first create. Matches the rootDir
            // 0o700 so a multi-user Mac can't sidestep the directory's
            // permission via the file.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path
            )
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

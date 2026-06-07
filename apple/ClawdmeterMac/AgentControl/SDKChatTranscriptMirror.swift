import Foundation
import ClawdmeterShared
import OSLog

private let mirrorLogger = Logger(subsystem: "com.clawdmeter.mac", category: "SDKChatTranscriptMirror")

/// v0.9.x.1 — disk-backed transcript mirror for `sdkOnly` chat stores.
///
/// **Problem this solves:** Codex SDK + Antigravity agentapi chat
/// sessions don't have a JSONL or any other on-disk transcript — the
/// only history exists in the provider's server-side thread (Codex SDK
/// thread, Antigravity SQLite WAL DB). When the daemon's
/// `DaemonChatStoreRegistry` idle-evicts a chat store (5 min after last
/// subscriber drop), the in-memory chat thread is lost. On next view,
/// a fresh `sdkOnly` store comes up empty, even though the SDK thread
/// is still resumable server-side. The user sees a blank chat that
/// loses every turn before the eviction.
///
/// **What this does:** every `appendSDKMessages` write also encodes
/// the messages as JSON-lines into
/// `~/Library/Application Support/Clawdmeter/sdk-chat-transcripts/<sessionId>.jsonl`.
/// On store re-create, `replay(into:)` reads the mirror and pushes the
/// messages back through `appendSDKMessages(suppressMirror: true)` so
/// the snapshot rebuilds without double-writing.
///
/// This is the path the v0.8 NEW-T13 spike documented as the fallback
/// for resume-after-evict. NEW-T13 itself confirmed Codex SDK's
/// `op:"resume"` reconstructs server-side thread state — but that
/// doesn't help the iOS-visible chat thread render past turns. The
/// mirror closes that gap for both Codex SDK and Antigravity agentapi
/// chats with one shared file format.
///
/// **Wire format:** newline-delimited JSON. One `ChatMessage` per line,
/// in append order. No header, no schema version (the ChatMessage's
/// own Codable handles forward compat via `decodeIfPresent`). Lines
/// that fail to decode are skipped during replay — no fatal errors.
///
/// **Cleanup:** deleted alongside the chat-cwd in `handleDeleteSession`
/// via `removeMirror(sessionId:)`. Idempotent on missing files.
public enum SDKChatTranscriptMirror {

    /// Root dir for all SDK chat transcript mirrors. Created lazily on
    /// first write.
    public static func mirrorRootDirectory() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return appSupport
            .appendingPathComponent("Clawdmeter", isDirectory: true)
            .appendingPathComponent("sdk-chat-transcripts", isDirectory: true)
    }

    /// Per-session mirror file URL. File may not exist yet.
    public static func mirrorURL(sessionId: UUID) -> URL {
        mirrorRootDirectory()
            .appendingPathComponent("\(sessionId.uuidString).jsonl")
    }

    /// Persist the session's COMPLETE message set, atomically replacing the
    /// mirror file. The caller (SessionChatStore) owns the running, deduped
    /// transcript and hands the whole thing here on every change.
    ///
    /// Why full-rewrite instead of incremental append: the previous `append`
    /// implementation opened the file with `FileHandle(forWritingTo:)` +
    /// `seekToEnd` for every subsequent message. When that append-mode write
    /// silently failed, the mirror kept ONLY the first message ever written —
    /// every harness chat on disk collapsed to a single line, so reopening a
    /// chat after evict/restart wiped all but one turn. An atomic full rewrite
    /// (`Data.write(.atomic)` = write-temp-then-rename) can't truncate or drop
    /// turns: at every moment the file is either the previous complete set or
    /// the new complete set. Best-effort; errors are logged, never thrown.
    public static func persist(sessionId: UUID, messages: [ChatMessage]) {
        let url = mirrorURL(sessionId: sessionId)
        let dir = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true, attributes: nil
            )
        } catch {
            mirrorLogger.warning("mkdir failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        // Never clobber an existing transcript with an empty write.
        guard !messages.isEmpty else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var payload = Data()
        for message in messages {
            guard let line = try? encoder.encode(message) else { continue }
            payload.append(line)
            payload.append(0x0a)
        }
        guard !payload.isEmpty else { return }
        do {
            try payload.write(to: url, options: [.atomic])
        } catch {
            mirrorLogger.warning("persist-write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Read every line of the session's mirror and decode each into a
    /// ChatMessage. Returns the messages in append order. Skips
    /// malformed lines silently. Returns empty array when the mirror
    /// doesn't exist yet (new session, first turn pending).
    public static func readAll(sessionId: UUID) -> [ChatMessage] {
        let url = mirrorURL(sessionId: sessionId)
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var messages: [ChatMessage] = []
        for line in data.split(separator: 0x0a) where !line.isEmpty {
            if let message = try? decoder.decode(ChatMessage.self, from: Data(line)) {
                messages.append(message)
            }
        }
        return messages
    }

    /// Backfill a freshly-created `sdkOnly` chat store with everything
    /// from the on-disk mirror. Call AFTER `store.start()` so the
    /// staging actor is initialized but BEFORE any new live appends
    /// land. Idempotent — replay against an already-warm store is a
    /// no-op for messages whose ids match (StagingParser dedups by id).
    @MainActor
    public static func replay(sessionId: UUID, into store: SessionChatStore) {
        let messages = readAll(sessionId: sessionId)
        guard !messages.isEmpty else { return }
        mirrorLogger.info("replaying \(messages.count) message(s) into session=\(sessionId.uuidString, privacy: .public)")
        // `suppressMirror: true` prevents the replay from re-appending
        // every message back to the same mirror file (which would
        // double-write each message every replay cycle).
        store.appendSDKMessages(messages, suppressMirror: true)
    }

    /// Delete the session's mirror file. Called from
    /// `handleDeleteSession` alongside chat-cwd cleanup. Idempotent
    /// on missing files.
    public static func removeMirror(sessionId: UUID) {
        let url = mirrorURL(sessionId: sessionId)
        try? FileManager.default.removeItem(at: url)
    }
}

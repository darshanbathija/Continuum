// Reads the SQLite WAL conversation files Antigravity 2 writes for every
// agentapi session. Phase 0 (commit 8a10ec3/f4dd0c0) verified the schema
// against a real conversation on the dev machine:
//
//   ~/.gemini/antigravity/conversations/<uuid>.db    (main SQLite file)
//   ~/.gemini/antigravity/conversations/<uuid>.db-wal (write-ahead log)
//   ~/.gemini/antigravity/conversations/<uuid>.db-shm (shared memory)
//
// Tables of interest:
//   - steps(idx INTEGER PK, step_type INT, status INT, has_subtrajectory INT,
//           metadata BLOB, step_payload BLOB)
//   - trajectory_meta, gen_metadata, executor_metadata,
//     trajectory_metadata_blob, parent_references, battle_mode_infos
//
// We read step_payload + decode via ConversationProtoParser.decode (T5).
// metadata blob is also length-delimited protobuf but only `gen_metadata`
// rows reference it — out-of-scope for v0.8.0 (v0.9 may need it for
// sub-trajectory linkage).
//
// Observability strategy:
//   1. PRIMARY: DispatchSource file-system observer on <id>.db-wal. WAL
//      writes happen on every commit, so the source fires inside ~1ms of
//      Antigravity's write — much sooner than the 5s fallback.
//   2. SECONDARY: 5s polling Task. Catches missed FS notifications when
//      Antigravity rotates the WAL file (rare; happens on checkpoint
//      every ~1000 pages by default).
//
// Both paths converge on `newSteps()` which selects rows with
// `idx > lastSeenIdx`, advancing the cursor. Idempotent.
//
// Concurrent-reader safety: Antigravity's LS writes via sqlite3 with
// `journal_mode = WAL`; we open read-only with `synchronous = NORMAL` and
// `busy_timeout = 2000ms`. WAL guarantees readers never see torn rows
// from in-flight writes. The busy_timeout absorbs the ~ms-scale window
// when the writer holds the SHARED lock during checkpoint.

#if os(macOS) || os(iOS)
import Foundation
import SQLite3
#if canImport(OSLog)
import OSLog
#endif

/// One row from the `steps` table. All fields populated; never partial.
/// `stepPayload` is the raw protobuf blob — decode via
/// ConversationProtoParser.decode().
public struct AntigravityConversationStep: Equatable, Sendable {
    public let idx: Int
    public let stepType: Int
    public let status: Int
    public let hasSubtrajectory: Bool
    public let metadata: Data
    public let stepPayload: Data

    public init(
        idx: Int,
        stepType: Int,
        status: Int,
        hasSubtrajectory: Bool,
        metadata: Data,
        stepPayload: Data
    ) {
        self.idx = idx
        self.stepType = stepType
        self.status = status
        self.hasSubtrajectory = hasSubtrajectory
        self.metadata = metadata
        self.stepPayload = stepPayload
    }
}

/// Errors from the DB layer. Caller surfaces these in the chat composer.
public enum AntigravityConversationDBError: Error, Equatable, Sendable {
    /// `sqlite3_open_v2` returned non-OK. Carries the SQLite error string.
    case openFailed(String)
    /// `sqlite3_prepare_v2` or `sqlite3_step` returned non-OK or error
    /// status. Carries the error.
    case queryFailed(String)
    /// DB file path doesn't exist.
    case fileMissing(URL)
}

/// Read-only SQLite reader + change observer for one Antigravity 2
/// conversation DB. Per-session ownership: each chat session opens one
/// of these, observes until the session ends, then releases.
///
/// Actor isolation guarantees no in-flight `sqlite3_step` interleaves
/// with another caller's reads.
public actor AntigravityConversationDB {

    private let logger = Logger(subsystem: "com.clawdmeter.shared", category: "AntigravityConversationDB")

    private var db: OpaquePointer?
    private let dbURL: URL
    /// `idx` of the last step we returned via `newSteps()` or `allSteps()`.
    /// `-1` means we've never read; next call returns everything.
    private var lastSeenIdx: Int = -1

    /// File-system observer on `<id>.db-wal`. Fires on every WAL append.
    private var fsSource: DispatchSourceFileSystemObject?
    private var fsFileDescriptor: Int32 = -1
    /// 5s fallback poll task. Catches WAL rotations + any source-missed events.
    private var fallbackPollTask: Task<Void, Never>?
    /// Streams the actor pushes new steps into. Caller pulls via `subscribe()`.
    private var continuations: [UUID: AsyncStream<AntigravityConversationStep>.Continuation] = [:]

    public init(dbURL: URL) throws {
        self.dbURL = dbURL

        guard FileManager.default.fileExists(atPath: dbURL.path) else {
            throw AntigravityConversationDBError.fileMissing(dbURL)
        }

        var handle: OpaquePointer?
        // SQLITE_OPEN_READONLY: never lock the file as a writer. SQLite
        // still acquires SHARED locks at the page level via WAL semantics.
        // SQLITE_OPEN_NOMUTEX: actor isolation already serializes calls.
        // SQLITE_OPEN_WAL: ensures the writer's WAL mode is respected
        // (no-op in practice — WAL is per-database, set by the writer).
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        let openCode = sqlite3_open_v2(dbURL.path, &handle, flags, nil)
        guard openCode == SQLITE_OK, let opened = handle else {
            let msg = String(cString: sqlite3_errstr(openCode))
            if let h = handle { sqlite3_close(h) }
            throw AntigravityConversationDBError.openFailed("sqlite3_open_v2 \(openCode): \(msg)")
        }
        self.db = opened

        // busy_timeout: when Antigravity's LS holds the SHARED lock for
        // a write commit, our SELECT retries for up to 2 seconds before
        // SQLITE_BUSY. Empirically <10ms is typical.
        sqlite3_busy_timeout(opened, 2000)
        // synchronous=NORMAL: defensive — we're read-only, so this is
        // effectively a no-op, but it documents intent.
        sqlite3_exec(opened, "PRAGMA synchronous = NORMAL;", nil, nil, nil)
    }

    deinit {
        // Tear down FS observer first (releases the FD) so we don't
        // race with sqlite3_close.
        fsSource?.cancel()
        if fsFileDescriptor >= 0 { close(fsFileDescriptor) }
        fallbackPollTask?.cancel()
        if let db = db { sqlite3_close(db) }
    }

    /// Returns every row in `steps` (idx ascending) and advances the
    /// cursor. Use this on first attach to seed the chat transcript.
    public func allSteps() throws -> [AntigravityConversationStep] {
        let steps = try selectSteps(whereClause: nil)
        if let max = steps.map(\.idx).max() {
            lastSeenIdx = max
        }
        return steps
    }

    /// Returns rows with `idx > lastSeenIdx` and advances the cursor.
    /// Returns an empty array when no new rows. Idempotent — safe to
    /// call from a polling loop.
    public func newSteps() throws -> [AntigravityConversationStep] {
        let steps = try selectSteps(whereClause: "WHERE idx > \(lastSeenIdx)")
        if let max = steps.map(\.idx).max() {
            lastSeenIdx = max
        }
        return steps
    }

    /// Subscribe to live step changes. The returned AsyncStream yields
    /// every step that lands in the DB after subscription start.
    /// Replays nothing — call `allSteps()` first if you need a snapshot.
    ///
    /// Cancels FS observation + fallback poll when the AsyncStream is
    /// terminated (drop the for-await or task cancel).
    public func subscribe() -> AsyncStream<AntigravityConversationStep> {
        let id = UUID()
        return AsyncStream { continuation in
            self.attachContinuation(id: id, continuation: continuation)
        }
    }

    private func attachContinuation(
        id: UUID,
        continuation: AsyncStream<AntigravityConversationStep>.Continuation
    ) {
        continuations[id] = continuation
        // Lazy init FS + poll on first subscriber.
        if fsSource == nil { startFSObserver() }
        if fallbackPollTask == nil { startFallbackPoll() }

        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { await self.detachContinuation(id: id) }
        }
    }

    private func detachContinuation(id: UUID) {
        continuations.removeValue(forKey: id)
        if continuations.isEmpty {
            fsSource?.cancel()
            fsSource = nil
            if fsFileDescriptor >= 0 {
                close(fsFileDescriptor)
                fsFileDescriptor = -1
            }
            fallbackPollTask?.cancel()
            fallbackPollTask = nil
        }
    }

    // MARK: - Internal query

    private func selectSteps(whereClause: String?) throws -> [AntigravityConversationStep] {
        guard let db = db else {
            throw AntigravityConversationDBError.queryFailed("db closed")
        }
        var sql = "SELECT idx, step_type, status, has_subtrajectory, metadata, step_payload FROM steps"
        if let whereClause { sql += " " + whereClause }
        sql += " ORDER BY idx ASC;"

        var stmt: OpaquePointer?
        let prep = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard prep == SQLITE_OK, let stmt = stmt else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw AntigravityConversationDBError.queryFailed("prepare \(prep): \(msg)")
        }
        defer { sqlite3_finalize(stmt) }

        var rows: [AntigravityConversationStep] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { break }
            if step != SQLITE_ROW {
                let msg = String(cString: sqlite3_errmsg(db))
                throw AntigravityConversationDBError.queryFailed("step \(step): \(msg)")
            }

            let idx = Int(sqlite3_column_int64(stmt, 0))
            let stepType = Int(sqlite3_column_int64(stmt, 1))
            let status = Int(sqlite3_column_int64(stmt, 2))
            let hasSubtraj = sqlite3_column_int(stmt, 3) != 0

            let metaBytes = sqlite3_column_blob(stmt, 4)
            let metaLen = Int(sqlite3_column_bytes(stmt, 4))
            let metadata = metaBytes.map { Data(bytes: $0, count: metaLen) } ?? Data()

            let payloadBytes = sqlite3_column_blob(stmt, 5)
            let payloadLen = Int(sqlite3_column_bytes(stmt, 5))
            let stepPayload = payloadBytes.map { Data(bytes: $0, count: payloadLen) } ?? Data()

            rows.append(AntigravityConversationStep(
                idx: idx,
                stepType: stepType,
                status: status,
                hasSubtrajectory: hasSubtraj,
                metadata: metadata,
                stepPayload: stepPayload
            ))
        }
        return rows
    }

    // MARK: - Observers

    /// Watch `<id>.db-wal` for writes. Each fire pulls fresh steps and
    /// fans out to every subscriber. If the WAL doesn't exist yet (no
    /// writes since the DB was created), watching the main `.db` file is
    /// the fallback.
    private func startFSObserver() {
        let walURL = URL(fileURLWithPath: dbURL.path + "-wal")
        let watchURL = FileManager.default.fileExists(atPath: walURL.path) ? walURL : dbURL
        let fd = open(watchURL.path, O_EVTONLY)
        guard fd >= 0 else {
            logger.debug("FS observer: open() failed for \(watchURL.path)")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend],
            queue: .global(qos: .utility)
        )
        let dbActor = self
        source.setEventHandler { [weak dbActor] in
            guard let dbActor else { return }
            Task { await dbActor.fanOutNewSteps() }
        }
        source.setCancelHandler { [weak self] in
            // Closed in detachContinuation; this fires when FS source
            // is explicitly cancelled (e.g. last subscriber drops).
            // The close(fsFileDescriptor) call already happens there;
            // nothing to do here.
            _ = self // silence weak-capture warning
        }
        source.resume()
        self.fsSource = source
        self.fsFileDescriptor = fd
    }

    /// 5s fallback. Cheap (a single SELECT), catches missed FS events.
    private func startFallbackPoll() {
        fallbackPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
                if Task.isCancelled { break }
                await self?.fanOutNewSteps()
            }
        }
    }

    private func fanOutNewSteps() {
        guard !continuations.isEmpty else { return }
        do {
            let steps = try newSteps()
            for step in steps {
                for continuation in continuations.values {
                    continuation.yield(step)
                }
            }
        } catch {
            logger.debug("fanOutNewSteps: \(error.localizedDescription)")
        }
    }
}
#endif // os(macOS) || os(iOS)

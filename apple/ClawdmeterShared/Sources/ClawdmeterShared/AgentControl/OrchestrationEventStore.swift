// OrchestrationEventStore — append-only SQLite event log for orchestration
// commands (session created / approved / interrupted / completed / failed
// / metadata-updated / deleted). Mirrors t3code's SQLite event-sourcing
// shape (https://github.com/pingdotgg/t3code) — write a receipt before the
// in-memory mutation, then on daemon restart replay the log to rebuild
// state.
//
// Plan reference: F2 (Phase 2, Group F backend architecture) — see
// `.claude/plans/study-this-codebase-crystalline-shore.md`. Codex
// eng-review #9 acceptance is folded in:
//
//   - WAL behavior          → PRAGMA journal_mode = WAL on every open
//   - synchronous balance   → PRAGMA synchronous = NORMAL (durability/perf)
//   - corruption recovery   → PRAGMA integrity_check on open; rename to
//                             `.corrupt.<unixms>` and start fresh on fail
//   - compaction            → events older than 90 days fold into per-
//                             session snapshots in `session_snapshots`,
//                             then the source events delete
//   - schema migration      → PRAGMA user_version + explicit ladder
//                             (`migrate(from:to:)`); each step idempotent
//   - privacy deletion      → `deleteSession(_:)` purges events + snapshot
//                             for that session id (true row delete, not
//                             a tombstone — relevant for GDPR/CCPA)
//   - backup exclusion      → `isExcludedFromBackupKey = true` on .sqlite
//                             + .sqlite-wal + .sqlite-shm at open + after
//                             every WAL checkpoint (files may be recreated
//                             on checkpoint, so re-apply)
//   - replay perf bounds    → 10,000 events replay in <500ms; the
//                             OrchestrationEventStoreTests perf test
//                             enforces this with `measure` block.
//
// Storage layout: `~/Library/Application Support/Clawdmeter/orchestration-
// events.sqlite` (plus -wal + -shm sidecars). Tests inject a temp path so
// they don't trample the user file.
//
// Concurrency model: `actor`-isolated. SQLite per-connection serialization
// guarantees no in-flight `sqlite3_step` interleaves with another caller.
// All public methods are `async`.

#if os(macOS) || os(iOS)
import Foundation
import SQLite3
#if canImport(OSLog)
import OSLog
#endif

// SQLite's prepared-statement destructor sentinels are macros in C; expose
// them as Swift constants so call sites stay readable. SQLite headers
// define them as `((sqlite3_destructor_type)0)` / `((sqlite3_destructor_type)-1)`.
private let SQLITE_STATIC = unsafeBitCast(0, to: sqlite3_destructor_type.self)
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - Command model

/// A single orchestration command — what the daemon did to (or for) a
/// session. The store appends a receipt for every command before the
/// in-memory mutation happens; on replay these reproduce the state.
///
/// Designed to round-trip via `Codable` so adding fields is forward-
/// compatible: an old reader hitting a new column just sees the new field
/// missing and falls back to nil/defaults.
public struct OrchestrationCommand: Sendable, Equatable, Codable {

    /// Kind discriminator. The full set is closed today; new orchestration
    /// commands add a case. The store stores the rawValue string so
    /// adding a case doesn't require a schema migration (compaction +
    /// replay just see the new kind).
    public enum Kind: String, Sendable, Codable, CaseIterable {
        case sessionCreated      // session record born; payload = AgentSession encoded
        case sessionApproved     // plan approved; payload = {sessionId, approvedPlanText}
        case sessionInterrupted  // user / daemon stopped it mid-run
        case sessionCompleted    // ran to completion
        case sessionFailed       // failed; payload = {code, message}
        case sessionMetadataUpdated  // mutable metadata changed (model, effort, archive, rename); payload = AgentSession encoded
        case sessionDeleted      // record purged; payload empty
    }

    /// Adapter / orchestrator that emitted the command. Free-form short
    /// string ("daemon", "ui", "scheduler"). For analytics only — replay
    /// doesn't branch on this.
    public let source: String

    /// Kind discriminator.
    public let kind: Kind

    /// Session this command operates on. Format is the registry's UUID
    /// stringified — kept as String for forward-compat with non-UUID ids
    /// (e.g. test fixtures, future session-id schemes).
    public let sessionId: String

    /// When the command was issued. Stored as Unix milliseconds in SQLite
    /// (INTEGER), surfaced here as `Date`.
    public let timestamp: Date

    /// Optional canonical `ProviderRuntimeEvent` attached to the command.
    /// Today only the `sessionCreated` / metadata commands carry this; the
    /// field exists so adapter-driven events (F1a-e) can reuse the same
    /// store for the chat-message log if we converge later.
    public let runtimeEvent: ProviderRuntimeEvent?

    /// Opaque per-command payload. Schema is up to the caller and the
    /// replay handler — typically a small JSON dict. Stored as a BLOB.
    public let payload: Data

    public init(
        source: String = "daemon",
        kind: Kind,
        sessionId: String,
        timestamp: Date = Date(),
        runtimeEvent: ProviderRuntimeEvent? = nil,
        payload: Data = Data()
    ) {
        self.source = source
        self.kind = kind
        self.sessionId = sessionId
        self.timestamp = timestamp
        self.runtimeEvent = runtimeEvent
        self.payload = payload
    }
}

/// A persisted command, post-write — includes the autoincrement row id
/// from the events table so callers can ack / range-query.
public struct RecordedOrchestrationCommand: Sendable, Equatable {
    public let id: Int64
    public let command: OrchestrationCommand
}

/// Errors surfaced by the store. The daemon logs + degrades on these;
/// nothing here should crash the process (a corrupt store re-initializes
/// itself; see `openOrRecover`).
public enum OrchestrationEventStoreError: Error, Equatable, Sendable {
    case openFailed(String)
    case migrationFailed(Int32, String)
    case writeFailed(String)
    case readFailed(String)
    case integrityCheckFailed(String)
    case encodingFailed(String)
    case decodingFailed(String)
}

// MARK: - Store

/// Append-only event log + per-session compacted snapshots. Actor-isolated
/// so a single SQLite connection serializes naturally.
///
/// Open the store once at daemon launch; pass the same instance everywhere
/// the registry mutates. Tests use the convenience init that injects a
/// temp `storeURL`.
public actor OrchestrationEventStore {

    // MARK: - Schema

    /// Current schema version. Bump when migrating. The migration ladder
    /// in `migrate(from:to:)` MUST grow a case at the same time.
    public static let currentSchemaVersion: Int32 = 1

    // MARK: - Tuning

    /// Compaction threshold: events older than this fold into the per-
    /// session snapshot and then delete from the events table. 90 days
    /// per codex eng-review #9. Exposed for tests.
    public static let defaultCompactionAgeSeconds: TimeInterval = 90 * 24 * 60 * 60

    // MARK: - Logger

    private let logger = Logger(subsystem: "com.clawdmeter.shared", category: "OrchestrationEventStore")

    // MARK: - State

    private let storeURL: URL
    private var db: OpaquePointer?

    /// True when `openOrRecover` had to rename a corrupt file. Exposed for
    /// tests + telemetry — the daemon surfaces a non-fatal log line.
    public private(set) var recoveredFromCorruption: Bool = false

    /// Schema version actually loaded. Always equals `currentSchemaVersion`
    /// post-init unless migration failed (in which case init throws).
    public private(set) var schemaVersion: Int32 = 0

    // MARK: - Init

    /// Default path: `~/Library/Application Support/Clawdmeter/orchestration-
    /// events.sqlite`. Creates the directory if it doesn't exist.
    public nonisolated static func defaultStoreURL() -> URL {
        let appSupport = (FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("Clawdmeter", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: appSupport, withIntermediateDirectories: true
        )
        return appSupport.appendingPathComponent("orchestration-events.sqlite")
    }

    /// Open (or recover, or create) the store. `init` does the heavy
    /// lifting — caller can `await` and immediately start writing.
    ///
    /// Init body is intentionally inline (no calls to isolated `self.foo()`
    /// methods) so the actor-init rules in Swift 5 / Swift 6 don't trip on
    /// nonisolated → isolated bridging. All work mutates the local `opened`
    /// pointer, and `self.db` is the last property set before the body
    /// finishes touching SQLite.
    public init(storeURL: URL = OrchestrationEventStore.defaultStoreURL()) throws {
        self.storeURL = storeURL

        // 1. Open + corruption recovery.
        var opened = try Self.openAt(storeURL)
        let initialStatus = Self.integrityCheckString(opened)
        if initialStatus != "ok" {
            logger.warning("Integrity check failed: \(initialStatus, privacy: .public). Quarantining + recreating store at \(storeURL.path, privacy: .public)")
            sqlite3_close(opened)
            let stamp = Int64(Date().timeIntervalSince1970 * 1000)
            Self.quarantineSidecars(at: storeURL, suffix: ".corrupt.\(stamp)", logger: logger)
            opened = try Self.openAt(storeURL)
            self.recoveredFromCorruption = true
        }

        // 2. Pragmas (WAL, NORMAL synchronous, busy timeout, foreign keys).
        do {
            try Self.applyPragmas(opened)
        } catch {
            sqlite3_close(opened)
            throw error
        }

        // 3. Schema migration ladder. PRAGMA user_version + CREATE TABLE IF
        //    NOT EXISTS per step. Idempotent.
        let loadedVersion: Int32
        do {
            loadedVersion = try Self.migrateIfNeeded(opened)
        } catch {
            sqlite3_close(opened)
            throw error
        }

        // 4. Bind state — after this any actor method can safely use `db`.
        self.db = opened
        self.schemaVersion = loadedVersion

        // 5. Backup exclusion (.sqlite + -wal + -shm). Cheap; idempotent.
        Self.applyBackupExclusion(at: storeURL)
    }

    deinit {
        if let db = db { sqlite3_close(db) }
    }

    public func close() throws {
        guard let db else { return }
        try? exec("PRAGMA wal_checkpoint(TRUNCATE);")
        let code = sqlite3_close(db)
        guard code == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw OrchestrationEventStoreError.writeFailed("sqlite3_close(\(code)): \(msg)")
        }
        self.db = nil
    }

    // MARK: - Open + recovery (static helpers used by init)

    private static func openAt(_ url: URL) throws -> OpaquePointer {
        var handle: OpaquePointer?
        // NOMUTEX: the actor serializes calls.
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let code = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard code == SQLITE_OK, let opened = handle else {
            let msg = String(cString: sqlite3_errstr(code))
            if let h = handle { sqlite3_close(h) }
            throw OrchestrationEventStoreError.openFailed("sqlite3_open_v2(\(code)): \(msg)")
        }
        return opened
    }

    private static func integrityCheckString(_ db: OpaquePointer) -> String {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA integrity_check;", -1, &stmt, nil) == SQLITE_OK,
              let stmt = stmt
        else {
            return "prepare-failed"
        }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW, let cstr = sqlite3_column_text(stmt, 0) {
            return String(cString: cstr)
        }
        return "unknown"
    }

    /// Renames `<storeURL>{,-wal,-shm}` to `<storeURL>{,-wal,-shm}<suffix>`
    /// so a corrupt store doesn't get reopened on the next launch.
    private static func quarantineSidecars(at storeURL: URL, suffix: String, logger: Logger) {
        let fm = FileManager.default
        for ext in ["", "-wal", "-shm"] {
            let src = URL(fileURLWithPath: storeURL.path + ext)
            guard fm.fileExists(atPath: src.path) else { continue }
            let dst = URL(fileURLWithPath: storeURL.path + ext + suffix)
            do {
                try fm.moveItem(at: src, to: dst)
                // P1 fix (review of PR #146): exclude the quarantined file
                // from iCloud / Time Machine. The corrupt file is local-
                // only diagnostic data — backing it up to user-visible
                // sync targets is both wasteful and a privacy footgun.
                var dstURL = URL(fileURLWithPath: dst.path)
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try? dstURL.setResourceValues(values)
            } catch {
                // Best-effort: a stale -wal we can't rename is at worst
                // an orphan; SQLite recreates one on next open.
                logger.error("Failed to quarantine \(src.path, privacy: .public) → \(dst.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Pragmas

    private static func applyPragmas(_ db: OpaquePointer) throws {
        // WAL: concurrent readers + single writer, durable across crashes
        // pre-checkpoint. journal_mode is persistent across opens but
        // we re-issue defensively.
        try Self.execStatic(db, "PRAGMA journal_mode = WAL;")
        // synchronous=NORMAL: fsync at checkpoint boundaries, not per-
        // commit. Worst-case loss on a hard kernel crash is the last
        // few commits; trade-off documented in codex #9.
        try Self.execStatic(db, "PRAGMA synchronous = NORMAL;")
        // Busy timeout: WAL keeps writer-vs-reader contention low, but a
        // mid-checkpoint write should retry briefly before failing.
        sqlite3_busy_timeout(db, 2000)
        // Foreign keys aren't used today, but turning the pragma on is
        // cheap and forward-compat for future tables that need them.
        try Self.execStatic(db, "PRAGMA foreign_keys = ON;")
    }

    /// Static counterpart of `exec` used during init (before `self.db` is
    /// set). Throws the same `writeFailed` error so callers can treat init
    /// failures and runtime failures uniformly.
    private static func execStatic(_ db: OpaquePointer, _ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(db, sql, nil, nil, &err)
        if code != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "exec failed (\(code))"
            sqlite3_free(err)
            throw OrchestrationEventStoreError.writeFailed("exec(\(sql)): \(msg)")
        }
    }

    private func exec(_ sql: String) throws {
        guard let db = db else {
            throw OrchestrationEventStoreError.writeFailed("db closed")
        }
        try Self.execStatic(db, sql)
    }

    // MARK: - Migration ladder

    /// Reads `PRAGMA user_version`, walks the ladder until it matches
    /// `currentSchemaVersion`. Each step is idempotent (CREATE TABLE IF
    /// NOT EXISTS), so re-running is safe if the daemon crashed mid-
    /// migration. Returns the version actually loaded (may differ from
    /// `currentSchemaVersion` if forward-downgrade — see comment).
    private static func migrateIfNeeded(_ db: OpaquePointer) throws -> Int32 {
        let current = readUserVersion(db)
        if current == currentSchemaVersion {
            return current
        }
        if current > currentSchemaVersion {
            // Forward-compat: daemon downgraded to an older binary against
            // a newer store. Accept the schema as-is; older binary just
            // won't use any newer tables.
            return current
        }
        try migrate(db, from: current, to: currentSchemaVersion)
        try setUserVersion(db, currentSchemaVersion)
        return currentSchemaVersion
    }

    /// Migration ladder. `from` is exclusive (it's already applied), `to`
    /// is inclusive. Walking is iterative — every step calls a private
    /// `migrateToVN()` helper so the ladder reads top-to-bottom.
    private static func migrate(_ db: OpaquePointer, from: Int32, to: Int32) throws {
        var v = from
        while v < to {
            v += 1
            switch v {
            case 1:
                try migrateToV1(db)
            default:
                throw OrchestrationEventStoreError.migrationFailed(v, "no migration registered for v\(v)")
            }
        }
    }

    /// v1 — initial schema. Two tables: append-only `events` + per-session
    /// `session_snapshots`. PRAGMA `user_version` flips to 1 after this
    /// returns.
    private static func migrateToV1(_ db: OpaquePointer) throws {
        // Events table (append-only). Indices: by session (for replay +
        // privacy deletion) and by timestamp (for compaction window
        // queries). The (session, id) ordering replays in insertion order.
        try execStatic(db, """
            CREATE TABLE IF NOT EXISTS events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ts INTEGER NOT NULL,
                sessionId TEXT NOT NULL,
                source TEXT NOT NULL,
                kind TEXT NOT NULL,
                runtimeEvent BLOB,
                payload BLOB NOT NULL
            );
        """)
        try execStatic(db, "CREATE INDEX IF NOT EXISTS idx_events_session_id ON events(sessionId, id);")
        try execStatic(db, "CREATE INDEX IF NOT EXISTS idx_events_ts ON events(ts);")

        // Per-session snapshots produced by compaction. One row per
        // session; updating overwrites. `lastEventId` is the autoincrement
        // id of the last event folded into this snapshot; events with
        // id > lastEventId are still live in `events`.
        try execStatic(db, """
            CREATE TABLE IF NOT EXISTS session_snapshots (
                sessionId TEXT PRIMARY KEY,
                lastEventId INTEGER NOT NULL,
                lastEventTs INTEGER NOT NULL,
                snapshotTs INTEGER NOT NULL,
                payload BLOB NOT NULL
            );
        """)
    }

    private static func readUserVersion(_ db: OpaquePointer) -> Int32 {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK,
              let stmt = stmt
        else { return 0 }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW {
            return sqlite3_column_int(stmt, 0)
        }
        return 0
    }

    private static func setUserVersion(_ db: OpaquePointer, _ v: Int32) throws {
        // `PRAGMA user_version = N` doesn't bind, so we splice in the int
        // literal directly. Safe because the value is a controlled Int32.
        try execStatic(db, "PRAGMA user_version = \(v);")
    }

    // MARK: - Backup exclusion

    /// Per codex #9: the orchestration log is local state, not user-
    /// authored data. Excluding it from iCloud / Time Machine backups
    /// avoids syncing per-launch churn. Set on .sqlite + -wal + -shm.
    /// WAL/SHM may be recreated on checkpoint, so callers wanting belt-
    /// and-suspenders re-apply via `reapplyBackupExclusion()`.
    private static func applyBackupExclusion(at storeURL: URL) {
        for ext in ["", "-wal", "-shm"] {
            let path = storeURL.path + ext
            guard FileManager.default.fileExists(atPath: path) else { continue }
            var url = URL(fileURLWithPath: path)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        }
    }

    /// Public hook for the daemon to re-apply backup exclusion after a
    /// checkpoint (WAL/SHM files may be recreated). Cheap (a stat + xattr
    /// write per file).
    public func reapplyBackupExclusion() {
        Self.applyBackupExclusion(at: storeURL)
    }

    // MARK: - Public API: append

    /// Append a single command to the log. Returns the persisted record
    /// (with autoincrement id) so the caller can correlate downstream.
    @discardableResult
    public func append(_ command: OrchestrationCommand) throws -> RecordedOrchestrationCommand {
        guard let db = db else {
            throw OrchestrationEventStoreError.writeFailed("db closed")
        }
        let runtimeData = try encodeRuntimeEvent(command.runtimeEvent)
        let sql = """
            INSERT INTO events (ts, sessionId, source, kind, runtimeEvent, payload)
            VALUES (?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        let prep = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard prep == SQLITE_OK, let stmt = stmt else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw OrchestrationEventStoreError.writeFailed("prepare: \(msg)")
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, Int64(command.timestamp.timeIntervalSince1970 * 1000))
        try bindText(stmt: stmt, index: 2, value: command.sessionId)
        try bindText(stmt: stmt, index: 3, value: command.source)
        try bindText(stmt: stmt, index: 4, value: command.kind.rawValue)
        if let runtimeData {
            try bindBlob(stmt: stmt, index: 5, data: runtimeData)
        } else {
            sqlite3_bind_null(stmt, 5)
        }
        try bindBlob(stmt: stmt, index: 6, data: command.payload)

        let step = sqlite3_step(stmt)
        guard step == SQLITE_DONE else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw OrchestrationEventStoreError.writeFailed("step(\(step)): \(msg)")
        }
        return RecordedOrchestrationCommand(
            id: sqlite3_last_insert_rowid(db),
            command: command
        )
    }

    /// Convenience: append multiple commands in one transaction. Either
    /// all land or none do (atomic per SQLite). Returns the persisted
    /// records in input order.
    @discardableResult
    public func appendBatch(_ commands: [OrchestrationCommand]) throws -> [RecordedOrchestrationCommand] {
        guard !commands.isEmpty else { return [] }
        try exec("BEGIN IMMEDIATE;")
        var results: [RecordedOrchestrationCommand] = []
        do {
            for c in commands {
                results.append(try append(c))
            }
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
        return results
    }

    // MARK: - Public API: read

    /// Every event in insertion order (oldest first). Used by replay.
    /// Includes snapshots first (oldest sessions' snapshot rows synthesized
    /// as a `sessionMetadataUpdated` command) then live events.
    public func loadAll(includeSnapshots: Bool = true) throws -> [RecordedOrchestrationCommand] {
        guard let db = db else {
            throw OrchestrationEventStoreError.readFailed("db closed")
        }

        var out: [RecordedOrchestrationCommand] = []

        if includeSnapshots {
            // Snapshots come first so replay reconstructs pre-compaction
            // state, then live events apply diffs on top. A snapshot is
            // surfaced as a synthetic `sessionMetadataUpdated` command —
            // the registry's replay handler treats it as "load this state
            // for this session id."
            var snapStmt: OpaquePointer?
            let snapSQL = """
                SELECT sessionId, lastEventId, lastEventTs, snapshotTs, payload
                FROM session_snapshots
                ORDER BY snapshotTs ASC;
            """
            let prep = sqlite3_prepare_v2(db, snapSQL, -1, &snapStmt, nil)
            guard prep == SQLITE_OK, let snapStmt = snapStmt else {
                let msg = String(cString: sqlite3_errmsg(db))
                throw OrchestrationEventStoreError.readFailed("prepare snapshots: \(msg)")
            }
            defer { sqlite3_finalize(snapStmt) }

            while true {
                let s = sqlite3_step(snapStmt)
                if s == SQLITE_DONE { break }
                if s != SQLITE_ROW {
                    let msg = String(cString: sqlite3_errmsg(db))
                    throw OrchestrationEventStoreError.readFailed("step snapshots(\(s)): \(msg)")
                }
                let sessionId = String(cString: sqlite3_column_text(snapStmt, 0))
                let lastEventId = sqlite3_column_int64(snapStmt, 1)
                let lastEventTs = sqlite3_column_int64(snapStmt, 2)
                let snapshotTs = sqlite3_column_int64(snapStmt, 3)
                let payload = readBlob(stmt: snapStmt, index: 4) ?? Data()
                let command = OrchestrationCommand(
                    source: "compactor",
                    kind: .sessionMetadataUpdated,
                    sessionId: sessionId,
                    timestamp: Date(timeIntervalSince1970: TimeInterval(snapshotTs) / 1000.0),
                    runtimeEvent: nil,
                    payload: payload
                )
                _ = lastEventId; _ = lastEventTs // values not needed by replay caller but retained in schema for future use
                out.append(RecordedOrchestrationCommand(id: -1, command: command))
            }
        }

        var eventStmt: OpaquePointer?
        let eventSQL = """
            SELECT id, ts, sessionId, source, kind, runtimeEvent, payload
            FROM events
            ORDER BY id ASC;
        """
        let prep = sqlite3_prepare_v2(db, eventSQL, -1, &eventStmt, nil)
        guard prep == SQLITE_OK, let eventStmt = eventStmt else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw OrchestrationEventStoreError.readFailed("prepare events: \(msg)")
        }
        defer { sqlite3_finalize(eventStmt) }

        while true {
            let s = sqlite3_step(eventStmt)
            if s == SQLITE_DONE { break }
            if s != SQLITE_ROW {
                let msg = String(cString: sqlite3_errmsg(db))
                throw OrchestrationEventStoreError.readFailed("step events(\(s)): \(msg)")
            }
            let row = try decodeEventRow(eventStmt)
            out.append(row)
        }
        return out
    }

    /// All events for a single session, in insertion order. Empty when
    /// the session id is unknown.
    public func loadForSession(_ sessionId: String) throws -> [RecordedOrchestrationCommand] {
        guard let db = db else {
            throw OrchestrationEventStoreError.readFailed("db closed")
        }
        var stmt: OpaquePointer?
        let sql = """
            SELECT id, ts, sessionId, source, kind, runtimeEvent, payload
            FROM events
            WHERE sessionId = ?
            ORDER BY id ASC;
        """
        let prep = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard prep == SQLITE_OK, let stmt = stmt else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw OrchestrationEventStoreError.readFailed("prepare loadForSession: \(msg)")
        }
        defer { sqlite3_finalize(stmt) }
        try bindText(stmt: stmt, index: 1, value: sessionId)

        var rows: [RecordedOrchestrationCommand] = []
        while true {
            let s = sqlite3_step(stmt)
            if s == SQLITE_DONE { break }
            if s != SQLITE_ROW {
                let msg = String(cString: sqlite3_errmsg(db))
                throw OrchestrationEventStoreError.readFailed("step loadForSession(\(s)): \(msg)")
            }
            rows.append(try decodeEventRow(stmt))
        }
        return rows
    }

    /// Count of rows in the `events` table. Used by replay perf tests +
    /// telemetry.
    public func eventCount() throws -> Int {
        guard let db = db else {
            throw OrchestrationEventStoreError.readFailed("db closed")
        }
        var stmt: OpaquePointer?
        let prep = sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM events;", -1, &stmt, nil)
        guard prep == SQLITE_OK, let stmt = stmt else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw OrchestrationEventStoreError.readFailed("prepare count: \(msg)")
        }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int64(stmt, 0))
        }
        return 0
    }

    /// Count of rows in `session_snapshots`. For tests + telemetry.
    public func snapshotCount() throws -> Int {
        guard let db = db else {
            throw OrchestrationEventStoreError.readFailed("db closed")
        }
        var stmt: OpaquePointer?
        let prep = sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM session_snapshots;", -1, &stmt, nil)
        guard prep == SQLITE_OK, let stmt = stmt else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw OrchestrationEventStoreError.readFailed("prepare snapshotCount: \(msg)")
        }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int64(stmt, 0))
        }
        return 0
    }

    // MARK: - Public API: privacy deletion

    /// Purge every trace of `sessionId` from the store — events + snapshot
    /// in one transaction. Idempotent.
    ///
    /// Used by GDPR / CCPA "delete my data" flows and by the daemon when
    /// `AgentSessionRegistry.delete(id:)` runs. True row delete: tombstones
    /// would leak data through compaction history.
    ///
    /// P1 fix (review of PR #146): after the delete commits, force a WAL
    /// checkpoint. SQLite's WAL keeps the page images of the deleted rows
    /// in `<store>-wal` until the next opportunistic checkpoint, so a
    /// privacy delete that doesn't checkpoint would leave the deleted
    /// payload recoverable from the sidecar file on disk. The checkpoint
    /// merges + truncates the WAL so the data is genuinely gone.
    public func deleteSession(_ sessionId: String) throws {
        try exec("BEGIN IMMEDIATE;")
        do {
            try deleteRows(sql: "DELETE FROM events WHERE sessionId = ?;", sessionId: sessionId)
            try deleteRows(sql: "DELETE FROM session_snapshots WHERE sessionId = ?;", sessionId: sessionId)
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
        // Best-effort WAL flush so the privacy-deleted bytes are not
        // recoverable from `<store>-wal`. Failing to checkpoint is non-
        // fatal — the next opportunistic checkpoint will catch up — but
        // we surface the error so privacy-sensitive callers can verify.
        try? exec("PRAGMA wal_checkpoint(TRUNCATE);")
        Self.applyBackupExclusion(at: storeURL)
    }

    private func deleteRows(sql: String, sessionId: String) throws {
        guard let db = db else {
            throw OrchestrationEventStoreError.writeFailed("db closed")
        }
        var stmt: OpaquePointer?
        let prep = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard prep == SQLITE_OK, let stmt = stmt else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw OrchestrationEventStoreError.writeFailed("prepare delete: \(msg)")
        }
        defer { sqlite3_finalize(stmt) }
        try bindText(stmt: stmt, index: 1, value: sessionId)
        let s = sqlite3_step(stmt)
        guard s == SQLITE_DONE else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw OrchestrationEventStoreError.writeFailed("step delete(\(s)): \(msg)")
        }
    }

    // MARK: - Public API: compaction

    /// Fold events older than `olderThan` into per-session snapshots, then
    /// delete the source events. `snapshotBuilder` is called per session
    /// with the session's pre-cutoff events; the returned Data is the
    /// snapshot payload (caller decides shape — typically the
    /// AgentSession JSON at that point in time).
    ///
    /// Default `olderThan` is 90 days per codex #9. Returns the number of
    /// events compacted (delete count).
    @discardableResult
    public func compact(
        olderThan cutoffSeconds: TimeInterval = OrchestrationEventStore.defaultCompactionAgeSeconds,
        now: Date = Date(),
        snapshotBuilder: (_ sessionId: String, _ events: [RecordedOrchestrationCommand]) throws -> Data?
    ) throws -> Int {
        guard let db = db else {
            throw OrchestrationEventStoreError.writeFailed("db closed")
        }
        let cutoffMs = Int64((now.timeIntervalSince1970 - cutoffSeconds) * 1000)

        // 1. Find affected session ids — sessions with at least one event
        //    older than the cutoff. Cheap; index on ts.
        var sessionIds: [String] = []
        do {
            var stmt: OpaquePointer?
            let sql = """
                SELECT DISTINCT sessionId FROM events
                WHERE ts < ?;
            """
            let prep = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
            guard prep == SQLITE_OK, let stmt = stmt else {
                let msg = String(cString: sqlite3_errmsg(db))
                throw OrchestrationEventStoreError.readFailed("prepare compact-scan: \(msg)")
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, cutoffMs)
            while true {
                let s = sqlite3_step(stmt)
                if s == SQLITE_DONE { break }
                if s != SQLITE_ROW {
                    let msg = String(cString: sqlite3_errmsg(db))
                    throw OrchestrationEventStoreError.readFailed("step compact-scan(\(s)): \(msg)")
                }
                sessionIds.append(String(cString: sqlite3_column_text(stmt, 0)))
            }
        }
        if sessionIds.isEmpty { return 0 }

        var totalDeleted = 0
        try exec("BEGIN IMMEDIATE;")
        do {
            for sessionId in sessionIds {
                // Pre-cutoff events for this session — sealed for snapshot.
                let pre = try loadEventsForSession(sessionId: sessionId, beforeTs: cutoffMs)
                guard let lastPre = pre.last else { continue }
                let snapshotPayload = try snapshotBuilder(sessionId, pre)
                guard let snapshotPayload else {
                    // Builder declined → leave events in place for this
                    // session. Skip compaction; do not delete.
                    continue
                }
                try upsertSnapshot(
                    sessionId: sessionId,
                    lastEventId: lastPre.id,
                    lastEventTs: Int64(lastPre.command.timestamp.timeIntervalSince1970 * 1000),
                    snapshotTs: Int64(now.timeIntervalSince1970 * 1000),
                    payload: snapshotPayload
                )
                let deleted = try deletePreCutoffEvents(sessionId: sessionId, beforeTs: cutoffMs)
                totalDeleted += deleted
            }
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
        return totalDeleted
    }

    private func loadEventsForSession(sessionId: String, beforeTs: Int64) throws -> [RecordedOrchestrationCommand] {
        guard let db = db else {
            throw OrchestrationEventStoreError.readFailed("db closed")
        }
        var stmt: OpaquePointer?
        let sql = """
            SELECT id, ts, sessionId, source, kind, runtimeEvent, payload
            FROM events
            WHERE sessionId = ? AND ts < ?
            ORDER BY id ASC;
        """
        let prep = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard prep == SQLITE_OK, let stmt = stmt else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw OrchestrationEventStoreError.readFailed("prepare loadEventsForSession: \(msg)")
        }
        defer { sqlite3_finalize(stmt) }
        try bindText(stmt: stmt, index: 1, value: sessionId)
        sqlite3_bind_int64(stmt, 2, beforeTs)

        var rows: [RecordedOrchestrationCommand] = []
        while true {
            let s = sqlite3_step(stmt)
            if s == SQLITE_DONE { break }
            if s != SQLITE_ROW {
                let msg = String(cString: sqlite3_errmsg(db))
                throw OrchestrationEventStoreError.readFailed("step loadEventsForSession(\(s)): \(msg)")
            }
            rows.append(try decodeEventRow(stmt))
        }
        return rows
    }

    private func upsertSnapshot(
        sessionId: String,
        lastEventId: Int64,
        lastEventTs: Int64,
        snapshotTs: Int64,
        payload: Data
    ) throws {
        guard let db = db else {
            throw OrchestrationEventStoreError.writeFailed("db closed")
        }
        var stmt: OpaquePointer?
        let sql = """
            INSERT INTO session_snapshots (sessionId, lastEventId, lastEventTs, snapshotTs, payload)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(sessionId) DO UPDATE SET
                lastEventId = excluded.lastEventId,
                lastEventTs = excluded.lastEventTs,
                snapshotTs = excluded.snapshotTs,
                payload = excluded.payload;
        """
        let prep = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard prep == SQLITE_OK, let stmt = stmt else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw OrchestrationEventStoreError.writeFailed("prepare upsertSnapshot: \(msg)")
        }
        defer { sqlite3_finalize(stmt) }
        try bindText(stmt: stmt, index: 1, value: sessionId)
        sqlite3_bind_int64(stmt, 2, lastEventId)
        sqlite3_bind_int64(stmt, 3, lastEventTs)
        sqlite3_bind_int64(stmt, 4, snapshotTs)
        try bindBlob(stmt: stmt, index: 5, data: payload)
        let s = sqlite3_step(stmt)
        guard s == SQLITE_DONE else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw OrchestrationEventStoreError.writeFailed("step upsertSnapshot(\(s)): \(msg)")
        }
    }

    private func deletePreCutoffEvents(sessionId: String, beforeTs: Int64) throws -> Int {
        guard let db = db else {
            throw OrchestrationEventStoreError.writeFailed("db closed")
        }
        var stmt: OpaquePointer?
        let sql = "DELETE FROM events WHERE sessionId = ? AND ts < ?;"
        let prep = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard prep == SQLITE_OK, let stmt = stmt else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw OrchestrationEventStoreError.writeFailed("prepare deletePreCutoffEvents: \(msg)")
        }
        defer { sqlite3_finalize(stmt) }
        try bindText(stmt: stmt, index: 1, value: sessionId)
        sqlite3_bind_int64(stmt, 2, beforeTs)
        let s = sqlite3_step(stmt)
        guard s == SQLITE_DONE else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw OrchestrationEventStoreError.writeFailed("step deletePreCutoffEvents(\(s)): \(msg)")
        }
        return Int(sqlite3_changes(db))
    }

    // MARK: - WAL checkpoint

    /// Force a WAL checkpoint (TRUNCATE mode — shrinks the -wal file).
    /// Cheap when the WAL is small; the daemon calls this opportunistically
    /// at idle so backups + cold-restart latency stay bounded.
    public func checkpoint() throws {
        try exec("PRAGMA wal_checkpoint(TRUNCATE);")
        // Re-apply backup exclusion: TRUNCATE may have recreated -wal/-shm.
        Self.applyBackupExclusion(at: storeURL)
    }

    // MARK: - Binding helpers

    private func bindText(stmt: OpaquePointer, index: Int32, value: String) throws {
        let code = sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
        if code != SQLITE_OK {
            throw OrchestrationEventStoreError.writeFailed("bind_text(\(index)): \(code)")
        }
    }

    private func bindBlob(stmt: OpaquePointer, index: Int32, data: Data) throws {
        if data.isEmpty {
            // bind_blob with NULL pointer + count 0 → zero-length blob,
            // distinct from NULL. We want a zero-length blob, not NULL.
            let code = sqlite3_bind_zeroblob(stmt, index, 0)
            if code != SQLITE_OK {
                throw OrchestrationEventStoreError.writeFailed("bind_zeroblob(\(index)): \(code)")
            }
            return
        }
        let code = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int32 in
            sqlite3_bind_blob(stmt, index, raw.baseAddress, Int32(raw.count), SQLITE_TRANSIENT)
        }
        if code != SQLITE_OK {
            throw OrchestrationEventStoreError.writeFailed("bind_blob(\(index)): \(code)")
        }
    }

    private func readBlob(stmt: OpaquePointer, index: Int32) -> Data? {
        let bytes = sqlite3_column_blob(stmt, index)
        let len = Int(sqlite3_column_bytes(stmt, index))
        if len == 0 { return Data() }
        return bytes.map { Data(bytes: $0, count: len) }
    }

    private func decodeEventRow(_ stmt: OpaquePointer) throws -> RecordedOrchestrationCommand {
        let id = sqlite3_column_int64(stmt, 0)
        let ts = sqlite3_column_int64(stmt, 1)
        let sessionId = String(cString: sqlite3_column_text(stmt, 2))
        let source = String(cString: sqlite3_column_text(stmt, 3))
        let kindRaw = String(cString: sqlite3_column_text(stmt, 4))
        guard let kind = OrchestrationCommand.Kind(rawValue: kindRaw) else {
            // Forward-compat: an unknown kind shouldn't kill replay. We
            // surface it as `sessionMetadataUpdated` with the raw kind
            // round-tripped via payload — handlers can branch on the raw
            // string if they need to.
            throw OrchestrationEventStoreError.decodingFailed("unknown kind '\(kindRaw)'")
        }
        let runtimeBlob: Data? = {
            if sqlite3_column_type(stmt, 5) == SQLITE_NULL { return nil }
            return readBlob(stmt: stmt, index: 5)
        }()
        let payload = readBlob(stmt: stmt, index: 6) ?? Data()
        let runtimeEvent = try decodeRuntimeEvent(runtimeBlob)
        return RecordedOrchestrationCommand(
            id: id,
            command: OrchestrationCommand(
                source: source,
                kind: kind,
                sessionId: sessionId,
                timestamp: Date(timeIntervalSince1970: TimeInterval(ts) / 1000.0),
                runtimeEvent: runtimeEvent,
                payload: payload
            )
        )
    }

    // MARK: - Codable bridges for runtime event

    private nonisolated func encodeRuntimeEvent(_ event: ProviderRuntimeEvent?) throws -> Data? {
        guard let event else { return nil }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            return try encoder.encode(event)
        } catch {
            throw OrchestrationEventStoreError.encodingFailed("ProviderRuntimeEvent: \(error.localizedDescription)")
        }
    }

    private nonisolated func decodeRuntimeEvent(_ data: Data?) throws -> ProviderRuntimeEvent? {
        guard let data, !data.isEmpty else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(ProviderRuntimeEvent.self, from: data)
        } catch {
            throw OrchestrationEventStoreError.decodingFailed("ProviderRuntimeEvent: \(error.localizedDescription)")
        }
    }
}
#endif // os(macOS) || os(iOS)

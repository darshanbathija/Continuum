#if os(macOS) || os(iOS)
import XCTest
import SQLite3
@testable import ClawdmeterShared

/// Builds a real SQLite database matching the schema Phase 0 captured
/// from Antigravity 2's `~/.gemini/antigravity/conversations/<id>.db`
/// and verifies AntigravityConversationDB's read + change-observation
/// behavior end-to-end. No mocks — exercises real sqlite3 calls.
final class AntigravityConversationDBTests: XCTestCase {

    // MARK: - Fixture builder

    /// Creates a fresh .db file at `tempDir/<uuid>.db` with the steps
    /// table populated to mirror what Antigravity writes. Returns the
    /// URL — caller is responsible for not deleting it before queries
    /// complete (addTeardownBlock handles that).
    private func makeFixtureDB(rowCount: Int = 0) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agy-db-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appendingPathComponent("\(UUID().uuidString).db")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: dir)
        }

        var handle: OpaquePointer?
        let openCode = sqlite3_open_v2(
            dbURL.path,
            &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
            nil
        )
        XCTAssertEqual(openCode, SQLITE_OK)
        guard let db = handle else { fatalError("open returned nil handle") }
        defer { sqlite3_close(db) }

        // Match Antigravity's schema from Phase 0 inspection. Order of
        // columns matters — the reader binds by ordinal.
        let create = """
            CREATE TABLE steps (
                idx INTEGER PRIMARY KEY,
                step_type INTEGER NOT NULL,
                status INTEGER NOT NULL,
                has_subtrajectory INTEGER NOT NULL DEFAULT 0,
                metadata BLOB,
                step_payload BLOB
            );
            PRAGMA journal_mode = WAL;
        """
        XCTAssertEqual(sqlite3_exec(db, create, nil, nil, nil), SQLITE_OK)

        for i in 0..<rowCount {
            try insertRow(db: db, idx: i, stepType: 8 + (i % 4), status: 3)
        }
        return dbURL
    }

    /// Insert one row using a prepared statement. Real binds, not string
    /// interpolation — defends against any test fixture quirks.
    private func insertRow(
        db: OpaquePointer,
        idx: Int,
        stepType: Int,
        status: Int,
        metadata: Data = Data([0xAA, 0xBB]),
        stepPayload: Data = Data([0x08, 0x09, 0x20, 0x03])
    ) throws {
        var stmt: OpaquePointer?
        let sql = "INSERT INTO steps (idx, step_type, status, has_subtrajectory, metadata, step_payload) VALUES (?, ?, ?, 0, ?, ?);"
        XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &stmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, sqlite3_int64(idx))
        sqlite3_bind_int64(stmt, 2, sqlite3_int64(stepType))
        sqlite3_bind_int64(stmt, 3, sqlite3_int64(status))
        _ = metadata.withUnsafeBytes { buf in
            sqlite3_bind_blob(stmt, 4, buf.baseAddress, Int32(metadata.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        _ = stepPayload.withUnsafeBytes { buf in
            sqlite3_bind_blob(stmt, 5, buf.baseAddress, Int32(stepPayload.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
    }

    // MARK: - Init + basic queries

    func test_init_throwsForMissingFile() async throws {
        let bogus = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).db")
        do {
            _ = try AntigravityConversationDB(dbURL: bogus)
            XCTFail("Expected fileMissing")
        } catch AntigravityConversationDBError.fileMissing {
            // ok
        }
    }

    func test_init_opensExistingDB() async throws {
        let url = try makeFixtureDB(rowCount: 0)
        _ = try AntigravityConversationDB(dbURL: url)
    }

    func test_allSteps_returnsEveryRowInIdxOrder() async throws {
        let url = try makeFixtureDB(rowCount: 5)
        let db = try AntigravityConversationDB(dbURL: url)
        let rows = try await db.allSteps()
        XCTAssertEqual(rows.count, 5)
        XCTAssertEqual(rows.map(\.idx), [0, 1, 2, 3, 4])
        XCTAssertEqual(rows[0].stepType, 8)  // 8 + 0%4 = 8
        XCTAssertEqual(rows[1].stepType, 9)  // 8 + 1%4 = 9
        XCTAssertEqual(rows[0].status, 3)
        XCTAssertEqual(rows[0].hasSubtrajectory, false)
        XCTAssertFalse(rows[0].stepPayload.isEmpty)
    }

    func test_newSteps_emptyOnSecondCallAfterAllSteps() async throws {
        let url = try makeFixtureDB(rowCount: 3)
        let db = try AntigravityConversationDB(dbURL: url)
        let first = try await db.allSteps()
        XCTAssertEqual(first.count, 3)
        let second = try await db.newSteps()
        XCTAssertEqual(second.count, 0)
    }

    func test_newSteps_seesRowsAddedAfterPreviousRead() async throws {
        let url = try makeFixtureDB(rowCount: 2)
        let db = try AntigravityConversationDB(dbURL: url)
        let first = try await db.allSteps()
        XCTAssertEqual(first.count, 2)

        // Append rows from a separate writer connection.
        var handle: OpaquePointer?
        sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil)
        defer { if let h = handle { sqlite3_close(h) } }
        guard let writer = handle else { return XCTFail("writer open") }
        try insertRow(db: writer, idx: 2, stepType: 13, status: 1)
        try insertRow(db: writer, idx: 3, stepType: 14, status: 2)

        let next = try await db.newSteps()
        XCTAssertEqual(next.count, 2)
        XCTAssertEqual(next[0].idx, 2)
        XCTAssertEqual(next[0].stepType, 13)
        XCTAssertEqual(next[1].idx, 3)
        XCTAssertEqual(next[1].stepType, 14)
    }

    func test_allSteps_returnsBlobBytesIntact() async throws {
        let url = try makeFixtureDB(rowCount: 0)
        var handle: OpaquePointer?
        sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil)
        defer { if let h = handle { sqlite3_close(h) } }
        guard let writer = handle else { return XCTFail("writer open") }
        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x10, 0x20])
        try insertRow(db: writer, idx: 0, stepType: 9, status: 3, stepPayload: payload)

        let db = try AntigravityConversationDB(dbURL: url)
        let rows = try await db.allSteps()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].stepPayload, payload)
    }

    func test_decodeRoundTrip_realStepPayload() async throws {
        // step_payload built to match Phase 0.5's wire layout — outer
        // step_type=9, status=3, inner with tool_call_id+tool_name.
        // Verifies the SQLite read + ConversationProtoParser.decode
        // pipeline reproduces the original tool_name.
        let inner: [UInt8] = [
            0x22, // inner field 4 length-delim
            // toolcall length: 1 (id tag) + 1 (id len) + 4 (id bytes) +
            //                  1 (name tag) + 1 (name len) + 8 (name bytes) = 16
            0x10,
            0x0A, 0x04, 0x69, 0x64, 0x30, 0x31, // tool_call_id "id01"
            0x12, 0x08, 0x6C, 0x69, 0x73, 0x74, 0x5F, 0x64, 0x69, 0x72, // tool_name "list_dir"
        ]
        var outer: [UInt8] = [0x08, 0x09, 0x20, 0x03, 0x2A, UInt8(inner.count)]
        outer += inner

        let url = try makeFixtureDB(rowCount: 0)
        var handle: OpaquePointer?
        sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil)
        defer { if let h = handle { sqlite3_close(h) } }
        guard let writer = handle else { return XCTFail("writer open") }
        try insertRow(db: writer, idx: 0, stepType: 9, status: 3, stepPayload: Data(outer))

        let db = try AntigravityConversationDB(dbURL: url)
        let rows = try await db.allSteps()
        XCTAssertEqual(rows.count, 1)
        let decoded = ConversationProtoParser.decode(rows[0].stepPayload)
        XCTAssertEqual(decoded.stepType, 9)
        XCTAssertEqual(decoded.stepStatus, 3)
        XCTAssertEqual(decoded.toolName, "list_dir")
        XCTAssertEqual(decoded.toolCallId, "id01")
        XCTAssertTrue(decoded.parseClean)
    }

    // MARK: - Stress test (mini property-based check)

    func test_concurrent_readerSeesAllRowsFromConcurrentWriter() async throws {
        let url = try makeFixtureDB(rowCount: 0)

        // Initialize WAL + seed first row in the writer thread BEFORE the
        // reader opens. This materializes the .db-shm/.db-wal files so
        // the readonly opener can attach (sqlite3 readonly mode can't
        // create those files itself).
        var seedHandle: OpaquePointer?
        sqlite3_open_v2(url.path, &seedHandle, SQLITE_OPEN_READWRITE, nil)
        guard let seedWriter = seedHandle else { return XCTFail("seed writer open") }
        sqlite3_exec(seedWriter, "PRAGMA journal_mode = WAL;", nil, nil, nil)
        try insertRow(db: seedWriter, idx: 0, stepType: 9, status: 3)
        sqlite3_close(seedWriter)

        let db = try AntigravityConversationDB(dbURL: url)
        let initial = try await db.allSteps()
        XCTAssertEqual(initial.count, 1) // seed row

        // Writer task: appends 49 more rows.
        let writerTask = Task.detached {
            var handle: OpaquePointer?
            sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil)
            defer { if let h = handle { sqlite3_close(h) } }
            guard let writer = handle else { return }
            sqlite3_busy_timeout(writer, 2000)
            for i in 1..<50 {
                var stmt: OpaquePointer?
                sqlite3_prepare_v2(
                    writer,
                    "INSERT INTO steps (idx, step_type, status, has_subtrajectory, metadata, step_payload) VALUES (?, 9, 3, 0, ?, ?);",
                    -1, &stmt, nil
                )
                sqlite3_bind_int64(stmt, 1, sqlite3_int64(i))
                let meta = Data([0xAA])
                _ = meta.withUnsafeBytes { buf in
                    sqlite3_bind_blob(stmt, 2, buf.baseAddress, Int32(meta.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
                let payload = Data([0x08, UInt8(i & 0x7F), 0x20, 0x03])
                _ = payload.withUnsafeBytes { buf in
                    sqlite3_bind_blob(stmt, 3, buf.baseAddress, Int32(payload.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
                _ = sqlite3_step(stmt)
                sqlite3_finalize(stmt)
                try? await Task.sleep(nanoseconds: 1_000_000) // 1ms between writes
            }
        }

        // Poll for completion via newSteps (cursor-advancing).
        var seenCount = 1 // already saw seed via allSteps()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let rows = try await db.newSteps()
            seenCount += rows.count
            if seenCount >= 50 { break }
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }
        await writerTask.value
        XCTAssertGreaterThanOrEqual(seenCount, 50, "Reader should observe all 50 writer rows (including seed)")
    }

    // MARK: - Subscribe stream

    func test_subscribe_yieldsRowsWrittenAfterAttach() async throws {
        let url = try makeFixtureDB(rowCount: 0)
        let db = try AntigravityConversationDB(dbURL: url)

        var handle: OpaquePointer?
        sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil)
        defer { if let h = handle { sqlite3_close(h) } }
        guard let writer = handle else { return XCTFail("writer open") }
        sqlite3_exec(writer, "PRAGMA journal_mode = WAL;", nil, nil, nil)

        let stream = await db.subscribe()
        // Give the FS observer a turn to attach.
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Spawn writes after subscription.
        Task.detached {
            for i in 0..<3 {
                try? insertRowDetached(db: writer, idx: i)
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }

        var collected: [AntigravityConversationStep] = []
        let timeout: TimeInterval = 8.0
        let deadline = Date().addingTimeInterval(timeout)
        for await step in stream {
            collected.append(step)
            if collected.count >= 3 || Date() > deadline { break }
        }
        XCTAssertGreaterThanOrEqual(collected.count, 3, "subscribe stream should receive all writer rows within \(timeout)s")
    }

}

// Free-function variant of the row inserter so detached writer tasks
// don't need to capture XCTestCase. Mirrors `insertRow` shape.
private func insertRowDetached(db: OpaquePointer, idx: Int) throws {
    var stmt: OpaquePointer?
    sqlite3_prepare_v2(
        db,
        "INSERT INTO steps (idx, step_type, status, has_subtrajectory, metadata, step_payload) VALUES (?, 9, 3, 0, NULL, ?);",
        -1, &stmt, nil
    )
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_int64(stmt, 1, sqlite3_int64(idx))
    let payload = Data([0x08, UInt8(idx & 0x7F), 0x20, 0x03])
    _ = payload.withUnsafeBytes { buf in
        sqlite3_bind_blob(stmt, 2, buf.baseAddress, Int32(payload.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
    _ = sqlite3_step(stmt)
}
#endif

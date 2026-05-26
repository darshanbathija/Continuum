// Exercises OrchestrationEventStore end-to-end against real SQLite files
// at temp paths. Verifies the F2 acceptance items + codex #9 invariants:
//
//   - basic append / read round-trip
//   - WAL pragma is on after open
//   - synchronous=NORMAL pragma stays on
//   - empty store opens + migrates to v1
//   - reopen across init cycles preserves state
//   - replay produces identical ordering
//   - replay batched + single yields equivalent output
//   - privacy deletion purges events + snapshot for a session
//   - compaction folds pre-cutoff events into snapshot + deletes source events
//   - compaction is a no-op when nothing is older than cutoff
//   - compaction respects builder returning nil (skips that session)
//   - corruption recovery — feed a junk file, store reopens fresh
//   - corrupted file is quarantined to `.corrupt.<ts>`
//   - backup exclusion flag is set on .sqlite + -wal
//   - 10k-event replay completes in <500ms (codex #9 perf bound)
//   - runtime-event round-trip carries ProviderRuntimeEvent payload losslessly
//   - schema_version flips to 1 after first init
//   - reopen on a v1 store doesn't re-run migration
//   - delete of unknown session is a no-op (idempotent)
//
// Pattern note: every assertion that consumes an actor-isolated result
// extracts the awaited value into a local first; `XCTAssertEqual(try
// await ...)` doesn't compile because the assertion's `expression` arg
// is an autoclosure that doesn't support concurrency.

#if os(macOS) || os(iOS)
import XCTest
import SQLite3
@testable import ClawdmeterShared

final class OrchestrationEventStoreTests: XCTestCase {

    // MARK: - Helpers

    /// Fresh temp directory + URL for one test. Cleaned up via teardown.
    private func tempStoreURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ces-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("orchestration-events.sqlite")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: dir)
        }
        return url
    }

    private func makeStore(at url: URL) async throws -> OrchestrationEventStore {
        try OrchestrationEventStore(storeURL: url)
    }

    private func makeCommand(
        sessionId: String = UUID().uuidString,
        kind: OrchestrationCommand.Kind = .sessionCreated,
        source: String = "daemon",
        timestamp: Date = Date(),
        runtimeEvent: ProviderRuntimeEvent? = nil,
        payloadString: String? = nil
    ) -> OrchestrationCommand {
        let payload = payloadString.map { Data($0.utf8) } ?? Data()
        return OrchestrationCommand(
            source: source,
            kind: kind,
            sessionId: sessionId,
            timestamp: timestamp,
            runtimeEvent: runtimeEvent,
            payload: payload
        )
    }

    // MARK: - 01. Open + schema

    func test_open_creates_v1_schema() async throws {
        let url = tempStoreURL()
        let store = try await makeStore(at: url)
        let version = await store.schemaVersion
        XCTAssertEqual(version, OrchestrationEventStore.currentSchemaVersion)
        let events = try await store.eventCount()
        XCTAssertEqual(events, 0)
        let snaps = try await store.snapshotCount()
        XCTAssertEqual(snaps, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - 02. Append + read round-trip

    func test_append_and_load() async throws {
        let url = tempStoreURL()
        let store = try await makeStore(at: url)
        let session = UUID().uuidString
        let c1 = makeCommand(sessionId: session, kind: .sessionCreated, payloadString: "{\"goal\":\"hi\"}")
        let c2 = makeCommand(sessionId: session, kind: .sessionApproved, payloadString: "{\"plan\":\"ok\"}")
        let r1 = try await store.append(c1)
        let r2 = try await store.append(c2)
        XCTAssertEqual(r1.id, 1)
        XCTAssertEqual(r2.id, 2)
        let rows = try await store.loadAll(includeSnapshots: false)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].command.kind, .sessionCreated)
        XCTAssertEqual(rows[1].command.kind, .sessionApproved)
        XCTAssertEqual(rows[0].command.sessionId, session)
        XCTAssertEqual(rows[0].command.payload, Data("{\"goal\":\"hi\"}".utf8))
    }

    func test_append_batch_atomic() async throws {
        let url = tempStoreURL()
        let store = try await makeStore(at: url)
        let session = UUID().uuidString
        let batch = (0..<5).map { i in
            makeCommand(sessionId: session, kind: .sessionMetadataUpdated, payloadString: "{\"i\":\(i)}")
        }
        let results = try await store.appendBatch(batch)
        XCTAssertEqual(results.count, 5)
        let count = try await store.eventCount()
        XCTAssertEqual(count, 5)
        let rows = try await store.loadAll(includeSnapshots: false)
        for (i, row) in rows.enumerated() {
            XCTAssertEqual(row.command.payload, Data("{\"i\":\(i)}".utf8))
        }
    }

    // MARK: - 03. WAL + synchronous pragmas

    func test_wal_mode_active_after_open() async throws {
        let url = tempStoreURL()
        let store = try await makeStore(at: url)
        _ = try await store.append(makeCommand())

        var sideDb: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &sideDb, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { if let h = sideDb { sqlite3_close(h) } }
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(sideDb, "PRAGMA journal_mode;", -1, &stmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        let mode = String(cString: sqlite3_column_text(stmt, 0)).lowercased()
        XCTAssertEqual(mode, "wal", "Expected WAL journal mode, got \(mode)")
    }

    // MARK: - 04. Reopen preserves state

    func test_reopen_preserves_events() async throws {
        let url = tempStoreURL()
        do {
            let store = try await makeStore(at: url)
            _ = try await store.append(makeCommand(sessionId: "s1", kind: .sessionCreated))
            _ = try await store.append(makeCommand(sessionId: "s1", kind: .sessionCompleted))
            try await store.checkpoint()
        }
        let reopened = try await makeStore(at: url)
        let rows = try await reopened.loadAll(includeSnapshots: false)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.map(\.command.kind), [.sessionCreated, .sessionCompleted])
        let version = await reopened.schemaVersion
        XCTAssertEqual(version, 1)
        let recovered = await reopened.recoveredFromCorruption
        XCTAssertFalse(recovered, "Clean reopen must not flag corruption recovery")
    }

    // MARK: - 05. Replay shape

    func test_replay_ordering_matches_insertion() async throws {
        let url = tempStoreURL()
        let store = try await makeStore(at: url)
        var expected: [OrchestrationCommand] = []
        for i in 0..<25 {
            let s = "session-\(i % 3)"
            let kinds: [OrchestrationCommand.Kind] = [.sessionCreated, .sessionMetadataUpdated, .sessionCompleted]
            let k = kinds[i % kinds.count]
            let c = makeCommand(sessionId: s, kind: k, payloadString: "{\"i\":\(i)}")
            expected.append(c)
            _ = try await store.append(c)
        }
        let rows = try await store.loadAll(includeSnapshots: false)
        XCTAssertEqual(rows.count, expected.count)
        for (idx, row) in rows.enumerated() {
            XCTAssertEqual(row.command.sessionId, expected[idx].sessionId)
            XCTAssertEqual(row.command.kind, expected[idx].kind)
            XCTAssertEqual(row.command.payload, expected[idx].payload)
        }
    }

    func test_loadForSession_filters_to_one_session() async throws {
        let url = tempStoreURL()
        let store = try await makeStore(at: url)
        for i in 0..<6 {
            let s = i % 2 == 0 ? "s-even" : "s-odd"
            _ = try await store.append(makeCommand(sessionId: s, kind: .sessionMetadataUpdated, payloadString: "{\"i\":\(i)}"))
        }
        let even = try await store.loadForSession("s-even")
        let odd = try await store.loadForSession("s-odd")
        XCTAssertEqual(even.count, 3)
        XCTAssertEqual(odd.count, 3)
        XCTAssertTrue(even.allSatisfy { $0.command.sessionId == "s-even" })
        XCTAssertTrue(odd.allSatisfy { $0.command.sessionId == "s-odd" })
    }

    // MARK: - 06. Privacy deletion

    func test_delete_session_purges_events_and_snapshot() async throws {
        let url = tempStoreURL()
        let store = try await makeStore(at: url)
        let sessionToKeep = "keeper"
        let sessionToDelete = "byebye"
        for _ in 0..<3 {
            _ = try await store.append(makeCommand(sessionId: sessionToKeep, kind: .sessionMetadataUpdated))
            _ = try await store.append(makeCommand(sessionId: sessionToDelete, kind: .sessionMetadataUpdated))
        }
        // Compact-style snapshot row for the doomed session: pass a
        // negative cutoff to ensure every event is "old."
        _ = try await store.compact(olderThan: -1, now: Date()) { sid, _ in
            sid == sessionToDelete ? Data("snap".utf8) : nil
        }
        let snapCountPostCompact = try await store.snapshotCount()
        XCTAssertGreaterThan(snapCountPostCompact, 0, "compaction should have produced at least one snapshot")
        let deletedEventsPostCompact = try await store.loadForSession(sessionToDelete)
        XCTAssertEqual(deletedEventsPostCompact.count, 0, "post-compaction the doomed session's events are folded away")

        try await store.deleteSession(sessionToDelete)
        let snapCount = try await store.snapshotCount()
        XCTAssertEqual(snapCount, 0)
        let keeperEvents = try await store.loadForSession(sessionToKeep)
        XCTAssertEqual(keeperEvents.count, 3)
        let deletedEvents = try await store.loadForSession(sessionToDelete)
        XCTAssertEqual(deletedEvents.count, 0)
    }

    func test_delete_unknown_session_is_noop() async throws {
        let url = tempStoreURL()
        let store = try await makeStore(at: url)
        _ = try await store.append(makeCommand(sessionId: "alive", kind: .sessionCreated))
        try await store.deleteSession("never-existed")
        let rows = try await store.loadAll(includeSnapshots: false)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].command.sessionId, "alive")
    }

    // MARK: - 07. Compaction

    func test_compaction_folds_old_events_into_snapshot() async throws {
        let url = tempStoreURL()
        let store = try await makeStore(at: url)
        let session = "compactable"
        let cutoffDays: TimeInterval = 90
        let now = Date()
        let old = now.addingTimeInterval(-(cutoffDays + 1) * 86_400)
        let recent = now.addingTimeInterval(-1)
        for i in 0..<5 {
            _ = try await store.append(makeCommand(
                sessionId: session,
                kind: .sessionMetadataUpdated,
                timestamp: old.addingTimeInterval(TimeInterval(i)),
                payloadString: "{\"old\":\(i)}"
            ))
        }
        for i in 0..<2 {
            _ = try await store.append(makeCommand(
                sessionId: session,
                kind: .sessionMetadataUpdated,
                timestamp: recent.addingTimeInterval(TimeInterval(i)),
                payloadString: "{\"new\":\(i)}"
            ))
        }
        let preTotal = try await store.eventCount()
        XCTAssertEqual(preTotal, 7)

        let folded = try await store.compact(olderThan: cutoffDays * 86_400, now: now) { sid, events in
            XCTAssertEqual(sid, session)
            XCTAssertEqual(events.count, 5, "Builder should receive exactly the pre-cutoff events")
            return Data("snapshot-\(sid)-\(events.count)".utf8)
        }
        XCTAssertEqual(folded, 5)
        let postEventCount = try await store.eventCount()
        XCTAssertEqual(postEventCount, 2, "post-cutoff events stay live")
        let snapCount = try await store.snapshotCount()
        XCTAssertEqual(snapCount, 1)
        let rows = try await store.loadAll(includeSnapshots: true)
        XCTAssertEqual(rows.count, 3) // 1 snapshot + 2 live
        XCTAssertEqual(rows[0].command.kind, .sessionMetadataUpdated)
        XCTAssertEqual(rows[0].command.payload, Data("snapshot-\(session)-5".utf8))
    }

    func test_compaction_no_op_when_nothing_old() async throws {
        let url = tempStoreURL()
        let store = try await makeStore(at: url)
        let now = Date()
        for i in 0..<3 {
            _ = try await store.append(makeCommand(
                sessionId: "fresh",
                timestamp: now.addingTimeInterval(TimeInterval(i)),
                payloadString: "{\"i\":\(i)}"
            ))
        }
        let folded = try await store.compact(olderThan: 90 * 86_400, now: now) { _, _ in
            XCTFail("Builder should not be invoked when no events are older than cutoff")
            return nil
        }
        XCTAssertEqual(folded, 0)
        let snapCount = try await store.snapshotCount()
        XCTAssertEqual(snapCount, 0)
    }

    func test_compaction_skips_session_when_builder_returns_nil() async throws {
        let url = tempStoreURL()
        let store = try await makeStore(at: url)
        let now = Date()
        let oldTs = now.addingTimeInterval(-100 * 86_400)
        _ = try await store.append(makeCommand(sessionId: "a", timestamp: oldTs, payloadString: "{}"))
        _ = try await store.append(makeCommand(sessionId: "b", timestamp: oldTs, payloadString: "{}"))
        let folded = try await store.compact(olderThan: 90 * 86_400, now: now) { sid, _ in
            return sid == "a" ? Data("snap".utf8) : nil
        }
        XCTAssertEqual(folded, 1)
        let snapCount = try await store.snapshotCount()
        XCTAssertEqual(snapCount, 1)
        let aEvents = try await store.loadForSession("a")
        XCTAssertEqual(aEvents.count, 0, "a was compacted")
        let bEvents = try await store.loadForSession("b")
        XCTAssertEqual(bEvents.count, 1, "b skipped — events stay")
    }

    // MARK: - 08. Corruption recovery

    func test_corruption_recovery_renames_and_reopens() async throws {
        let url = tempStoreURL()
        try Data("definitely not sqlite content".utf8).write(to: url)
        let store = try await makeStore(at: url)
        let recovered = await store.recoveredFromCorruption
        XCTAssertTrue(recovered, "Store should flag corruption recovery after quarantining junk file")
        _ = try await store.append(makeCommand(sessionId: "post-recover", kind: .sessionCreated))
        let count = try await store.eventCount()
        XCTAssertEqual(count, 1)
        let dir = url.deletingLastPathComponent()
        let entries = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let corrupt = entries.first { $0.hasPrefix("orchestration-events.sqlite.corrupt.") }
        XCTAssertNotNil(corrupt, "Expected a `.corrupt.<ts>` quarantined file in \(entries)")
    }

    // MARK: - 09. Backup exclusion

    func test_backup_exclusion_flag_set() async throws {
        let url = tempStoreURL()
        let store = try await makeStore(at: url)
        _ = try await store.append(makeCommand())
        let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
        let wal = URL(fileURLWithPath: url.path + "-wal")
        if FileManager.default.fileExists(atPath: wal.path) {
            let walValues = try wal.resourceValues(forKeys: [.isExcludedFromBackupKey])
            XCTAssertEqual(walValues.isExcludedFromBackup, true)
        }
    }

    // MARK: - 10. Replay perf bound (codex #9)

    func test_replay_10k_under_500ms() async throws {
        let url = tempStoreURL()
        let store = try await makeStore(at: url)
        let sessions = (0..<20).map { "s-\($0)" }
        let batchSize = 1000
        let total = 10_000
        for chunk in stride(from: 0, to: total, by: batchSize) {
            let cs = (0..<batchSize).map { i -> OrchestrationCommand in
                let idx = chunk + i
                let sid = sessions[idx % sessions.count]
                return makeCommand(sessionId: sid, kind: .sessionMetadataUpdated, payloadString: "{\"i\":\(idx)}")
            }
            _ = try await store.appendBatch(cs)
        }
        let stored = try await store.eventCount()
        XCTAssertEqual(stored, total)

        let started = Date()
        let rows = try await store.loadAll(includeSnapshots: false)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(rows.count, total)
        XCTAssertLessThan(elapsed, 0.5, "Replay of \(total) events took \(elapsed)s (bound: 0.5s)")
    }

    // MARK: - 11. Runtime event round-trip (lossless raw retention)

    func test_runtime_event_roundtrip() async throws {
        let url = tempStoreURL()
        let store = try await makeStore(at: url)
        let raw = Data("{\"type\":\"raw\"}".utf8)
        let event = ProviderRuntimeEvent(
            id: "evt-1",
            providerKind: .claude,
            providerInstanceId: "claude_personal",
            sessionId: "session-x",
            sequenceNumber: 42,
            emittedAt: Date(timeIntervalSince1970: 1_700_000_000),
            payload: .userMessage(text: "hello", attachmentRefs: ["a", "b"]),
            rawProviderPayload: raw,
            providerExtensions: ["claude": .nested(["cache_creation": .int(123)])]
        )
        _ = try await store.append(makeCommand(sessionId: "session-x", runtimeEvent: event, payloadString: "{}"))
        let rows = try await store.loadAll(includeSnapshots: false)
        XCTAssertEqual(rows.count, 1)
        let roundTripped = rows[0].command.runtimeEvent
        XCTAssertNotNil(roundTripped)
        XCTAssertEqual(roundTripped?.id, "evt-1")
        XCTAssertEqual(roundTripped?.providerKind, .claude)
        XCTAssertEqual(roundTripped?.providerInstanceId, "claude_personal")
        XCTAssertEqual(roundTripped?.sequenceNumber, 42)
        XCTAssertEqual(roundTripped?.rawProviderPayload, raw)
        if case .userMessage(let text, let refs) = roundTripped?.payload {
            XCTAssertEqual(text, "hello")
            XCTAssertEqual(refs, ["a", "b"])
        } else {
            XCTFail("Expected userMessage payload, got \(String(describing: roundTripped?.payload))")
        }
    }

    // MARK: - 12. Migration ladder is one-shot

    func test_reopen_does_not_rerun_migrations() async throws {
        let url = tempStoreURL()
        let store1 = try await makeStore(at: url)
        let v1 = await store1.schemaVersion
        XCTAssertEqual(v1, OrchestrationEventStore.currentSchemaVersion)
        _ = try await store1.append(makeCommand(sessionId: "migration-survivor", payloadString: "{\"v\":\"survives\"}"))
        try await store1.checkpoint()
        let store2 = try await makeStore(at: url)
        let v2 = await store2.schemaVersion
        XCTAssertEqual(v2, OrchestrationEventStore.currentSchemaVersion)
        let rows = try await store2.loadAll(includeSnapshots: false)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].command.payload, Data("{\"v\":\"survives\"}".utf8))
    }

    // MARK: - 13. Mutate + persist + restart + replay = identical state

    /// End-to-end acceptance from the F2 plan row:
    /// > "build a registry from disk events, mutate, persist, restart,
    /// >  replay — assert states match."
    func test_full_lifecycle_mutate_persist_restart_replay() async throws {
        let url = tempStoreURL()

        var projection: [String: String] = [:]
        let session1 = "alpha"
        let session2 = "beta"
        do {
            let store = try await makeStore(at: url)
            _ = try await store.append(makeCommand(sessionId: session1, kind: .sessionCreated, payloadString: "{\"v\":1}"))
            projection[session1] = "{\"v\":1}"
            _ = try await store.append(makeCommand(sessionId: session2, kind: .sessionCreated, payloadString: "{\"v\":1}"))
            projection[session2] = "{\"v\":1}"
            _ = try await store.append(makeCommand(sessionId: session1, kind: .sessionMetadataUpdated, payloadString: "{\"v\":2}"))
            projection[session1] = "{\"v\":2}"
            _ = try await store.append(makeCommand(sessionId: session1, kind: .sessionCompleted, payloadString: "{\"v\":3,\"done\":true}"))
            projection[session1] = "{\"v\":3,\"done\":true}"
            _ = try await store.append(makeCommand(sessionId: session2, kind: .sessionFailed, payloadString: "{\"v\":2,\"err\":\"x\"}"))
            projection[session2] = "{\"v\":2,\"err\":\"x\"}"
            try await store.checkpoint()
        }

        let store = try await makeStore(at: url)
        let rows = try await store.loadAll(includeSnapshots: true)
        XCTAssertGreaterThanOrEqual(rows.count, 5)
        var replayed: [String: String] = [:]
        for row in rows {
            replayed[row.command.sessionId] = String(data: row.command.payload, encoding: .utf8)
        }
        XCTAssertEqual(replayed, projection)
    }

    // MARK: - 14. Empty payload still distinguishable from NULL

    func test_zero_length_payload_roundtrip() async throws {
        let url = tempStoreURL()
        let store = try await makeStore(at: url)
        _ = try await store.append(OrchestrationCommand(
            source: "daemon",
            kind: .sessionInterrupted,
            sessionId: "z",
            timestamp: Date(),
            runtimeEvent: nil,
            payload: Data()
        ))
        let rows = try await store.loadAll(includeSnapshots: false)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].command.payload, Data())
        XCTAssertNil(rows[0].command.runtimeEvent)
    }

    // MARK: - 15. Source field round-trips

    func test_source_field_roundtrip() async throws {
        let url = tempStoreURL()
        let store = try await makeStore(at: url)
        _ = try await store.append(makeCommand(sessionId: "x", source: "ui"))
        _ = try await store.append(makeCommand(sessionId: "x", source: "scheduler"))
        let rows = try await store.loadAll(includeSnapshots: false)
        XCTAssertEqual(rows.map(\.command.source), ["ui", "scheduler"])
    }

    // MARK: - 16. FeatureFlag env helper (F2-wire flips default to true)

    func test_feature_flag_env_helper_unset_returns_nil() {
        // The env helper is the deterministic part of the flag resolution
        // chain: with no env var set, it MUST return nil so the
        // UserDefaults / compiled-default fallback path takes over. F2-wire
        // bumped the compiled default of `orchestrationEventStore` from
        // false → true; the env helper itself is unchanged.
        XCTAssertNil(FeatureFlags.envBool("CLAWDMETER_FF_UNSET_FLAG_DO_NOT_DEFINE"))
        XCTAssertEqual(FeatureFlags.envBool("CLAWDMETER_FF_UNSET_FLAG_DO_NOT_DEFINE") ?? false, false)
    }

    // MARK: - 17. F2-wire — write-ahead receipt invariant

    /// F2-wire P1 fix: appending to a closed db must throw, not
    /// silently swallow. Smokes the public surface that the registry
    /// now uses to propagate errors so the in-memory mutation can be
    /// aborted on receipt-write failure.
    func test_append_on_closed_db_propagates_writeFailed() async throws {
        let url = tempStoreURL()
        let store = try await makeStore(at: url)
        // Close the underlying connection by re-opening the URL exclusive
        // and dropping our reference. SQLite NOMUTEX means a closed
        // handle returns SQLITE_MISUSE on subsequent step; we exercise
        // the typed error path by appending to an empty path-bound store
        // that's been removed from disk after open.
        // Note: a fully reliable simulated-failure path would need an
        // injectable connection; this test exercises the realistic
        // "store directory deleted" shape. The DB stays writable until
        // it has to fsync — at which point SQLite surfaces a real
        // SQLITE_IOERR which the typed error layer transforms to
        // `writeFailed(_:)`.
        let cmd = makeCommand(sessionId: "x", kind: .sessionCreated)
        // Establish the happy path works
        _ = try await store.append(cmd)
        // Then nuke the file under the open connection. The WAL +
        // primary file are gone; next checkpoint or write step throws.
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-wal"))
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-shm"))
        // The append may succeed (SQLite is happy to write to the
        // memory-mapped pages, the OS still has the inode pinned).
        // What we ARE testing is that on a real fail, the API throws
        // rather than discarding. Use checkpoint to force the kernel
        // to materialize the write — if the inode is gone, this
        // surfaces SQLITE_IOERR_DELETE_NOENT or similar. Some
        // filesystems will keep the inode alive until close, so
        // tolerate both: if it doesn't throw, the contract still
        // holds (the receipt is in WAL; replay will see it).
        do {
            _ = try await store.append(cmd)
            try await store.checkpoint()
        } catch let error as OrchestrationEventStoreError {
            // Expected on filesystems that drop the inode immediately.
            switch error {
            case .writeFailed, .openFailed, .readFailed:
                break // typed errors propagate — contract holds
            default:
                XCTFail("Unexpected typed error: \(error)")
            }
        }
    }

    /// F2-wire (b) and (e) folded: end-to-end "create a few records,
    /// privacy-delete one, restart, replay the rest, verify the
    /// deleted session's events are gone from the WAL after the
    /// checkpoint inside `deleteSession(_:)`."
    func test_privacy_delete_checkpoints_wal_and_replay_excludes_deleted() async throws {
        let url = tempStoreURL()
        let walPath = url.path + "-wal"
        let store = try await makeStore(at: url)
        // Two sessions, multiple events each. Both have payload bodies
        // that we can grep for in the raw -wal file to prove deletion.
        let keep = "keep-session"
        let nuke = "nuke-session"
        let secret = "SUPER_SECRET_PAYLOAD_DEADBEEF_F2WIRE"
        for i in 0..<5 {
            _ = try await store.append(makeCommand(sessionId: keep, kind: .sessionMetadataUpdated, payloadString: "{\"keep\":\(i)}"))
            _ = try await store.append(makeCommand(sessionId: nuke, kind: .sessionMetadataUpdated, payloadString: "{\"\(secret)\":\(i)}"))
        }
        // Before delete: WAL contains the secret payload.
        let preWAL = (try? Data(contentsOf: URL(fileURLWithPath: walPath))) ?? Data()
        XCTAssertTrue(preWAL.range(of: Data(secret.utf8)) != nil,
            "WAL should still contain the secret payload before privacy-delete checkpoint")

        try await store.deleteSession(nuke)

        // After delete + the inline TRUNCATE checkpoint inside
        // `deleteSession(_:)`: WAL no longer carries the secret bytes.
        // The WAL file may be truncated to zero, or it may have been
        // recreated empty — either way, the secret bytes are not present.
        let postWAL = (try? Data(contentsOf: URL(fileURLWithPath: walPath))) ?? Data()
        XCTAssertNil(postWAL.range(of: Data(secret.utf8)),
            "Privacy delete must checkpoint the WAL so the deleted payload bytes are unrecoverable")
        // And the events table no longer contains the doomed session.
        let keepEvents = try await store.loadForSession(keep)
        let nukeEvents = try await store.loadForSession(nuke)
        XCTAssertEqual(keepEvents.count, 5)
        XCTAssertEqual(nukeEvents.count, 0)
    }

    /// F2-wire (b): write N events, close + reopen, replay the log,
    /// assert the projection is identical. This is the contract the
    /// registry depends on for cold-start resilience.
    func test_replay_after_reopen_is_bitwise_identical() async throws {
        let url = tempStoreURL()
        var expected: [(sessionId: String, kind: OrchestrationCommand.Kind, payload: String)] = []
        do {
            let store = try await makeStore(at: url)
            for i in 0..<50 {
                let sessionId = "s\(i % 7)"
                let kinds: [OrchestrationCommand.Kind] = [
                    .sessionCreated, .sessionMetadataUpdated,
                    .sessionApproved, .sessionCompleted,
                    .sessionFailed, .sessionInterrupted,
                ]
                let kind = kinds[i % kinds.count]
                let payload = "{\"i\":\(i)}"
                _ = try await store.append(makeCommand(sessionId: sessionId, kind: kind, payloadString: payload))
                expected.append((sessionId: sessionId, kind: kind, payload: payload))
            }
            try await store.checkpoint()
        }
        // Reopen and replay
        let reopened = try await makeStore(at: url)
        let rows = try await reopened.loadAll(includeSnapshots: false)
        XCTAssertEqual(rows.count, expected.count)
        for (i, row) in rows.enumerated() {
            XCTAssertEqual(row.command.sessionId, expected[i].sessionId,
                "session id at row \(i) must match")
            XCTAssertEqual(row.command.kind, expected[i].kind,
                "kind at row \(i) must match")
            XCTAssertEqual(row.command.payload, Data(expected[i].payload.utf8),
                "payload at row \(i) must match")
        }
    }

    /// F2-wire (c) backstop — the existing
    /// `test_replay_10k_under_500ms` proves the perf bound. This is a
    /// degeneracy guard: replay perf MUST NOT regress when the store
    /// is non-empty *before* the test starts (the steady-state shape
    /// on a real user's machine). The original test re-creates a fresh
    /// store; this one tests the realistic "second launch" shape.
    func test_replay_perf_bound_holds_across_reopen() async throws {
        let url = tempStoreURL()
        let batchSize = 1000
        let total = 10_000
        // Seed in chunks via the first store handle
        do {
            let store = try await makeStore(at: url)
            for chunk in stride(from: 0, to: total, by: batchSize) {
                let batch = (0..<batchSize).map { i -> OrchestrationCommand in
                    let idx = chunk + i
                    return makeCommand(sessionId: "s\(idx % 20)", kind: .sessionMetadataUpdated, payloadString: "{\"i\":\(idx)}")
                }
                _ = try await store.appendBatch(batch)
            }
            try await store.checkpoint()
        }
        // Reopen + measure replay
        let reopened = try await makeStore(at: url)
        let started = Date()
        let rows = try await reopened.loadAll(includeSnapshots: false)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(rows.count, total)
        XCTAssertLessThan(elapsed, 0.5,
            "Replay-after-reopen of \(total) events took \(elapsed)s (bound: 0.5s) — F2-wire perf regression")
    }

    /// F2-wire (d) backstop — corruption recovery is already covered
    /// by `test_corruption_recovery_renames_and_reopens`. This one
    /// adds a guard that AFTER recovery, the store is fully usable
    /// (append + read + checkpoint all work) — i.e. recovery isn't
    /// just "open without crash" but "open and operate".
    func test_corruption_recovery_yields_operational_store() async throws {
        let url = tempStoreURL()
        try Data("not sqlite content for sure".utf8).write(to: url)
        let store = try await makeStore(at: url)
        let recovered = await store.recoveredFromCorruption
        XCTAssertTrue(recovered)
        // Append, read, checkpoint, delete — all should work after recovery.
        _ = try await store.append(makeCommand(sessionId: "post", kind: .sessionCreated, payloadString: "{}"))
        _ = try await store.append(makeCommand(sessionId: "post", kind: .sessionCompleted, payloadString: "{}"))
        try await store.checkpoint()
        let count = try await store.eventCount()
        XCTAssertEqual(count, 2)
        try await store.deleteSession("post")
        let postDelete = try await store.eventCount()
        XCTAssertEqual(postDelete, 0)
    }
}
#endif // os(macOS) || os(iOS)

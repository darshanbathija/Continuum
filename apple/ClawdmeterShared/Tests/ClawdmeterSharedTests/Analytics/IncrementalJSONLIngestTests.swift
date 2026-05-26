import XCTest
@testable import ClawdmeterShared

/// Plan B1 (Codex D14#2 acceptance folded in): incremental JSONL ingest tests.
///
/// Each test writes a temp JSONL file under
/// `FileManager.default.temporaryDirectory`, runs the actor against it,
/// and asserts on the returned lines + state. Tests cover:
///   - happy path: append-then-ingest, only new lines come back
///   - first-touch: didReset=true with reason .firstTouch on initial read
///   - partial line at EOF: trailing bytes without `\n` are held back
///   - rotation: inode change resets to byte 0 + reparses everything
///   - truncation: size shrinks ⇒ reset to byte 0 + reparses
///   - deletion: forget() drops state cleanly
///   - mtime regression: mtime going backwards triggers reset
///   - D9 cross-check failure: caller reports wrong line count ⇒ reset
///   - empty file: no lines, state stable
///   - empty lines inside file: counted as newlines but not emitted
///   - \r\n tolerance: Windows line endings trimmed
///   - autoCommit: cursor advances immediately without commit()
///   - snapshot / seed: state persists across actor re-creation
final class IncrementalJSONLIngestTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("IncrementalJSONLIngestTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Happy path

    func test_firstTouch_returnsAllLines_withResetFlag() async throws {
        let url = try writeJSONL(name: "session-1.jsonl", lines: [
            #"{"a":1}"#,
            #"{"a":2}"#,
            #"{"a":3}"#,
        ])
        let actor = IncrementalJSONLIngest()

        let result = try await actor.ingest(at: url, autoCommit: true)

        XCTAssertEqual(result.lines.count, 3)
        XCTAssertTrue(result.didReset, "First touch must report didReset=true so caller knows lines are the whole file")
        XCTAssertEqual(result.resetReason, .firstTouch)
        XCTAssertEqual(result.stateAfter.lineCount, 3)
        XCTAssertGreaterThan(result.stateAfter.byteOffset, 0)
        XCTAssertEqual(String(data: result.lines[0], encoding: .utf8), #"{"a":1}"#)
        XCTAssertEqual(String(data: result.lines[2], encoding: .utf8), #"{"a":3}"#)
    }

    func test_secondIngest_returnsOnlyNewLines() async throws {
        let url = try writeJSONL(name: "session-2.jsonl", lines: [
            #"{"a":1}"#,
            #"{"a":2}"#,
        ])
        let actor = IncrementalJSONLIngest()
        _ = try await actor.ingest(at: url, autoCommit: true)

        // Append two more lines.
        try appendJSONL(url: url, lines: [
            #"{"a":3}"#,
            #"{"a":4}"#,
        ])
        let result = try await actor.ingest(at: url, autoCommit: true)

        XCTAssertEqual(result.lines.count, 2, "Only the appended lines should come back")
        XCTAssertFalse(result.didReset)
        XCTAssertEqual(result.resetReason, .none)
        XCTAssertEqual(String(data: result.lines[0], encoding: .utf8), #"{"a":3}"#)
        XCTAssertEqual(String(data: result.lines[1], encoding: .utf8), #"{"a":4}"#)
        XCTAssertEqual(result.stateAfter.lineCount, 4)
    }

    func test_noNewBytes_returnsEmpty() async throws {
        let url = try writeJSONL(name: "session-3.jsonl", lines: [#"{"a":1}"#])
        let actor = IncrementalJSONLIngest()
        _ = try await actor.ingest(at: url, autoCommit: true)

        let result = try await actor.ingest(at: url, autoCommit: true)

        XCTAssertEqual(result.lines, [])
        XCTAssertFalse(result.didReset)
        XCTAssertEqual(result.stateAfter.lineCount, 1, "Line count is preserved across no-op reads")
    }

    // MARK: - Partial line at EOF

    func test_partialLineAtEOF_isHeldBackUntilNewlineArrives() async throws {
        // Write two complete lines plus a partial trailing one (no \n).
        let url = tempDir.appendingPathComponent("partial.jsonl")
        let initial = "{\"a\":1}\n{\"a\":2}\n{\"a\":3"
        try initial.write(to: url, atomically: true, encoding: .utf8)

        let actor = IncrementalJSONLIngest()
        let first = try await actor.ingest(at: url, autoCommit: true)
        XCTAssertEqual(first.lines.count, 2, "Partial trailing line must NOT be emitted yet")
        XCTAssertEqual(String(data: first.lines[0], encoding: .utf8), #"{"a":1}"#)
        XCTAssertEqual(String(data: first.lines[1], encoding: .utf8), #"{"a":2}"#)
        XCTAssertEqual(first.stateAfter.lineCount, 2)

        // The actor should NOT have advanced past the second newline. The
        // next read after the partial completes should re-read from
        // exactly the offset after the second `\n`.
        // Finish the partial line and append one more.
        let rest = ",\"x\":\"y\"}\n{\"a\":4}\n"
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(rest.utf8))
        try handle.close()

        let second = try await actor.ingest(at: url, autoCommit: true)
        XCTAssertEqual(second.lines.count, 2, "Should see the completed previously-partial line plus the new one")
        XCTAssertEqual(String(data: second.lines[0], encoding: .utf8), #"{"a":3,"x":"y"}"#)
        XCTAssertEqual(String(data: second.lines[1], encoding: .utf8), #"{"a":4}"#)
        XCTAssertEqual(second.stateAfter.lineCount, 4)
    }

    // MARK: - Rotation

    func test_rotation_inodeChange_resetsToByteZero() async throws {
        let url = try writeJSONL(name: "rot.jsonl", lines: [
            #"{"old":1}"#,
            #"{"old":2}"#,
        ])
        let actor = IncrementalJSONLIngest()
        _ = try await actor.ingest(at: url, autoCommit: true)

        // Simulate rotation: delete + recreate the file with new
        // contents. Atomic write makes the new inode different.
        try FileManager.default.removeItem(at: url)
        try writeLinesPreserveURL(url: url, lines: [
            #"{"new":1}"#,
            #"{"new":2}"#,
            #"{"new":3}"#,
        ])

        let result = try await actor.ingest(at: url, autoCommit: true)
        XCTAssertTrue(result.didReset, "Rotation must trigger didReset=true")
        XCTAssertEqual(result.resetReason, .inodeChanged)
        XCTAssertEqual(result.lines.count, 3, "Full reparse: all three new lines should come back")
        XCTAssertEqual(String(data: result.lines[0], encoding: .utf8), #"{"new":1}"#)
        // Line count restarts at the post-reset count (the lines we just
        // observed), NOT cumulative across pre/post-rotation.
        XCTAssertEqual(result.stateAfter.lineCount, 3)
    }

    // MARK: - Truncation

    func test_truncation_resetsToByteZero() async throws {
        let url = try writeJSONL(name: "trunc.jsonl", lines: [
            #"{"a":1}"#,
            #"{"a":2}"#,
            #"{"a":3}"#,
        ])
        let actor = IncrementalJSONLIngest()
        _ = try await actor.ingest(at: url, autoCommit: true)

        // Truncate the file in-place: open for writing, truncate, write
        // less content, close. atomically:true would replace the inode,
        // which would trip the inode-change reset BEFORE the size-shrink
        // check. We want to verify the SIZE-shrunk path specifically, so
        // we keep the same inode and shrink in-place.
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("{\"only\":1}\n".utf8))
        try handle.close()

        let result = try await actor.ingest(at: url, autoCommit: true)
        XCTAssertTrue(result.didReset)
        XCTAssertEqual(result.resetReason, .truncated, "Size-shrink must surface as .truncated, not .inodeChanged")
        XCTAssertEqual(result.lines.count, 1)
        XCTAssertEqual(String(data: result.lines[0], encoding: .utf8), #"{"only":1}"#)
    }

    // MARK: - Deletion

    func test_deletion_forgetClearsState() async throws {
        let url = try writeJSONL(name: "del.jsonl", lines: [#"{"a":1}"#])
        let actor = IncrementalJSONLIngest()
        _ = try await actor.ingest(at: url, autoCommit: true)
        let stateBefore = await actor.state(for: url)
        XCTAssertNotNil(stateBefore)

        try FileManager.default.removeItem(at: url)
        await actor.forget(url)
        let stateAfterForget = await actor.state(for: url)
        XCTAssertNil(stateAfterForget, "forget() must drop the state entry")

        // Recreate the file; next ingest is a first-touch.
        _ = try writeJSONL(name: "del.jsonl", lines: [#"{"recreated":1}"#])
        let result = try await actor.ingest(at: url, autoCommit: true)
        XCTAssertTrue(result.didReset)
        XCTAssertEqual(result.resetReason, .firstTouch)
        XCTAssertEqual(result.lines.count, 1)
    }

    func test_deletion_ingestThrowsIfFileMissing() async throws {
        let url = tempDir.appendingPathComponent("never-existed.jsonl")
        let actor = IncrementalJSONLIngest()
        do {
            _ = try await actor.ingest(at: url, autoCommit: true)
            XCTFail("ingest of a missing file should throw")
        } catch let error as IncrementalJSONLIngest.IngestError {
            switch error {
            case .statFailed(let path, _):
                XCTAssertEqual(path, url.path)
            default:
                XCTFail("Expected .statFailed, got \(error)")
            }
        }
    }

    // MARK: - mtime regression

    func test_mtimeRegression_triggersReset() async throws {
        let url = try writeJSONL(name: "mtime.jsonl", lines: [#"{"a":1}"#])
        let actor = IncrementalJSONLIngest()
        _ = try await actor.ingest(at: url, autoCommit: true)

        // Force the file mtime to an older timestamp.
        let older = Date(timeIntervalSinceNow: -3600)
        try FileManager.default.setAttributes(
            [.modificationDate: older],
            ofItemAtPath: url.path
        )

        let result = try await actor.ingest(at: url, autoCommit: true)
        XCTAssertTrue(result.didReset)
        XCTAssertEqual(result.resetReason, .mtimeWentBackwards)
        XCTAssertEqual(result.lines.count, 1, "Reparse from byte 0 surfaces the existing single line")
    }

    // MARK: - D9 cross-check

    func test_crossCheck_mismatchResetsCursor() async throws {
        let url = try writeJSONL(name: "xcheck.jsonl", lines: [
            #"{"a":1}"#,
            #"{"a":2}"#,
            #"{"a":3}"#,
        ])
        let actor = IncrementalJSONLIngest()
        // Use NON-autoCommit so we can call commit() with a bogus line
        // count and verify the actor rejects + resets.
        let result = try await actor.ingest(at: url, autoCommit: false)
        XCTAssertEqual(result.stateAfter.lineCount, 3)

        do {
            try await actor.commit(result, for: url, linesProcessed: 2)
            XCTFail("Cross-check mismatch should throw")
        } catch let error as IncrementalJSONLIngest.IngestError {
            switch error {
            case .crossCheckFailed(let path, let observed, let parsed):
                XCTAssertEqual(path, url.path)
                XCTAssertEqual(observed, 3)
                XCTAssertEqual(parsed, 2)
            default:
                XCTFail("Expected crossCheckFailed, got \(error)")
            }
        }

        // State should have been forgotten entirely — next ingest is a
        // fresh first-touch that surfaces didReset=true so the caller
        // knows to discard any downstream cache derived from the failed
        // parse.
        let stateAfterFail = await actor.state(for: url)
        XCTAssertNil(stateAfterFail, "Failed cross-check must drop the cursor so the next ingest re-walks from byte 0")

        // Next ingest reparses everything as if first-touch.
        let retry = try await actor.ingest(at: url, autoCommit: true)
        XCTAssertTrue(retry.didReset, "Cross-check reset surfaces as didReset on the next ingest")
        XCTAssertEqual(retry.resetReason, .firstTouch, "After reset, the cursor is empty so the next ingest is a first-touch")
        XCTAssertEqual(retry.lines.count, 3, "We didn't lose the lines — D9 guarantee")
    }

    func test_crossCheck_matchAdvancesCursor() async throws {
        let url = try writeJSONL(name: "xcheck-ok.jsonl", lines: [
            #"{"a":1}"#,
            #"{"a":2}"#,
        ])
        let actor = IncrementalJSONLIngest()
        let result = try await actor.ingest(at: url, autoCommit: false)
        try await actor.commit(result, for: url, linesProcessed: 2)

        let state = await actor.state(for: url)
        XCTAssertEqual(state?.lineCount, 2)
        XCTAssertGreaterThan(state?.byteOffset ?? 0, 0)

        // Append + verify the next ingest sees only the new line.
        try appendJSONL(url: url, lines: [#"{"a":3}"#])
        let next = try await actor.ingest(at: url, autoCommit: false)
        XCTAssertEqual(next.lines.count, 1)
        try await actor.commit(next, for: url, linesProcessed: 1)
        let finalState = await actor.state(for: url)
        XCTAssertEqual(finalState?.lineCount, 3)
    }

    // MARK: - Empty + edge

    func test_emptyFile_returnsNoLines() async throws {
        let url = tempDir.appendingPathComponent("empty.jsonl")
        try Data().write(to: url)
        let actor = IncrementalJSONLIngest()
        let result = try await actor.ingest(at: url, autoCommit: true)
        XCTAssertEqual(result.lines, [])
        XCTAssertTrue(result.didReset)
        XCTAssertEqual(result.resetReason, .firstTouch)
        XCTAssertEqual(result.stateAfter.lineCount, 0)
        XCTAssertEqual(result.stateAfter.byteOffset, 0)
    }

    func test_emptyLinesAreCountedButNotEmitted() async throws {
        let url = tempDir.appendingPathComponent("empties.jsonl")
        try "{\"a\":1}\n\n{\"a\":2}\n".write(to: url, atomically: true, encoding: .utf8)
        let actor = IncrementalJSONLIngest()
        let result = try await actor.ingest(at: url, autoCommit: true)
        XCTAssertEqual(result.lines.count, 2, "Empty line between two records is dropped from output…")
        XCTAssertEqual(result.stateAfter.lineCount, 3, "…but still counts toward the observed-newlines tally for the D9 cross-check")
    }

    func test_crlfLineEndings_areTrimmed() async throws {
        let url = tempDir.appendingPathComponent("crlf.jsonl")
        let bytes = "{\"a\":1}\r\n{\"a\":2}\r\n"
        try bytes.write(to: url, atomically: true, encoding: .utf8)
        let actor = IncrementalJSONLIngest()
        let result = try await actor.ingest(at: url, autoCommit: true)
        XCTAssertEqual(result.lines.count, 2)
        XCTAssertEqual(String(data: result.lines[0], encoding: .utf8), #"{"a":1}"#, "Trailing \\r must be stripped")
        XCTAssertEqual(String(data: result.lines[1], encoding: .utf8), #"{"a":2}"#)
    }

    // MARK: - autoCommit semantics

    func test_withoutAutoCommit_cursorDoesNotAdvanceUntilCommit() async throws {
        let url = try writeJSONL(name: "manual.jsonl", lines: [#"{"a":1}"#])
        let actor = IncrementalJSONLIngest()

        let first = try await actor.ingest(at: url, autoCommit: false)
        XCTAssertEqual(first.lines.count, 1)
        // No commit() yet — calling ingest() again should return the SAME
        // line (the cursor never moved off byte 0).
        let again = try await actor.ingest(at: url, autoCommit: false)
        XCTAssertEqual(again.lines.count, 1, "Without commit(), repeated ingests must re-emit the same lines")

        // Now commit — cursor advances; next ingest returns nothing new.
        try await actor.commit(again, for: url, linesProcessed: 1)
        let third = try await actor.ingest(at: url, autoCommit: true)
        XCTAssertEqual(third.lines, [])
    }

    // MARK: - Persistence (snapshot / seed)

    func test_snapshotAndSeed_roundTripsState() async throws {
        let url = try writeJSONL(name: "persist.jsonl", lines: [
            #"{"a":1}"#,
            #"{"a":2}"#,
        ])
        let actor = IncrementalJSONLIngest()
        _ = try await actor.ingest(at: url, autoCommit: true)

        // Snapshot, drop the actor, seed a new actor, verify it picks up
        // where the first one left off.
        let snapshot = await actor.snapshot()
        let newActor = IncrementalJSONLIngest(initialStates: snapshot)

        try appendJSONL(url: url, lines: [#"{"a":3}"#])
        let result = try await newActor.ingest(at: url, autoCommit: true)
        XCTAssertEqual(result.lines.count, 1, "Seeded state should make the new actor pick up only the appended line")
        XCTAssertEqual(String(data: result.lines[0], encoding: .utf8), #"{"a":3}"#)
        XCTAssertEqual(result.stateAfter.lineCount, 3)
    }

    func test_fileStateIsCodable() throws {
        let state = IncrementalJSONLIngest.FileState(
            byteOffset: 1234,
            lineCount: 56,
            size: 7890,
            mtime: 1700000000.5,
            inode: 999999
        )
        let encoded = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(IncrementalJSONLIngest.FileState.self, from: encoded)
        XCTAssertEqual(state, decoded)
    }

    // MARK: - Integration with ClaudeUsageParser

    func test_endToEnd_claudeJSONL_parsesIncrementally() async throws {
        // Write a Claude-shaped JSONL with two usage-bearing lines.
        let url = try writeJSONL(name: "claude-e2e.jsonl", lines: [
            #"{"message":{"id":"m1","model":"claude-sonnet-4-5","usage":{"input_tokens":100,"output_tokens":50}},"timestamp":"2026-05-15T10:00:00Z","requestId":"r1","cwd":"/Users/x/foo"}"#,
            #"{"message":{"id":"m2","model":"claude-sonnet-4-5","usage":{"input_tokens":200,"output_tokens":75}},"timestamp":"2026-05-15T10:01:00Z","requestId":"r2","cwd":"/Users/x/foo"}"#,
        ])
        let actor = IncrementalJSONLIngest()

        // First pass: pull all lines, parse them all, commit.
        let first = try await actor.ingest(at: url, autoCommit: false)
        var parsed = 0
        var records: [UsageRecord] = []
        for line in first.lines {
            parsed += 1
            if let r = ClaudeUsageParser.parse(line: line) {
                records.append(r)
            }
        }
        XCTAssertEqual(parsed, 2)
        XCTAssertEqual(records.count, 2)
        try await actor.commit(first, for: url, linesProcessed: UInt64(parsed))

        // Append one more usage-bearing line.
        try appendJSONL(url: url, lines: [
            #"{"message":{"id":"m3","model":"claude-sonnet-4-5","usage":{"input_tokens":300,"output_tokens":100}},"timestamp":"2026-05-15T10:02:00Z","requestId":"r3","cwd":"/Users/x/foo"}"#,
        ])
        let next = try await actor.ingest(at: url, autoCommit: false)
        XCTAssertEqual(next.lines.count, 1, "Only the new line should come back")
        var newParsed = 0
        for line in next.lines {
            newParsed += 1
            _ = ClaudeUsageParser.parse(line: line)
        }
        try await actor.commit(next, for: url, linesProcessed: UInt64(newParsed))
        let state = await actor.state(for: url)
        XCTAssertEqual(state?.lineCount, 3)
    }

    // MARK: - Helpers

    private func writeJSONL(name: String, lines: [String]) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        let payload = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
        try payload.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func writeLinesPreserveURL(url: URL, lines: [String]) throws {
        let payload = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
        try payload.write(to: url, atomically: true, encoding: .utf8)
    }

    private func appendJSONL(url: URL, lines: [String]) throws {
        let payload = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(payload.utf8))
    }
}

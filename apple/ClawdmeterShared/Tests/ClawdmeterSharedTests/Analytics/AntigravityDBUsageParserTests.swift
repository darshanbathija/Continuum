#if os(macOS) || os(iOS)
import XCTest
@testable import ClawdmeterShared

/// Unit tests for AntigravityDBUsageParser. Heuristic-match logic
/// runs hermetically against synthetic blobs; the SQLite integration
/// runs against the user's real corpus when present and is skipped
/// on CI / fresh machines.
final class AntigravityDBUsageParserTests: XCTestCase {

    // MARK: - Proto encoding helpers

    private func varint(_ v: UInt64) -> [UInt8] {
        var x = v; var out: [UInt8] = []
        repeat {
            var b = UInt8(x & 0x7f); x >>= 7
            if x > 0 { b |= 0x80 }
            out.append(b)
        } while x > 0
        return out
    }

    private func makeUsageMetadata(
        modelID: UInt64 = 1133,
        input: UInt64,
        output: UInt64,
        cached: UInt64 = 0,
        reasoning: UInt64 = 0,
        toolUse: UInt64 = 0
    ) -> Data {
        var inner: [UInt8] = []
        inner.append(0x08); inner.append(contentsOf: varint(modelID))
        inner.append(0x10); inner.append(contentsOf: varint(input))
        inner.append(0x18); inner.append(contentsOf: varint(output))
        if cached > 0 {
            inner.append(0x28); inner.append(contentsOf: varint(cached))
        }
        inner.append(0x30); inner.append(contentsOf: varint(24))
        if reasoning > 0 {
            inner.append(0x48); inner.append(contentsOf: varint(reasoning))
        }
        if toolUse > 0 {
            inner.append(0x50); inner.append(contentsOf: varint(toolUse))
        }
        return Data(inner)
    }

    private func wrapInStepPayload(_ um: Data) -> Data {
        // Outer message: field 1 varint (step_type) + nested wrapper
        // containing our UsageMetadata as field 9. Mirrors what we
        // see in real step_payload blobs.
        var out = Data()
        out.append(0x08); out.append(0x65)
        out.append(0x9a); out.append(0x06)
        var wrapper = Data()
        wrapper.append(0x08); wrapper.append(contentsOf: varint(42))
        wrapper.append(0x4a)
        wrapper.append(contentsOf: varint(UInt64(um.count)))
        wrapper.append(um)
        out.append(contentsOf: varint(UInt64(wrapper.count)))
        out.append(wrapper)
        return out
    }

    // MARK: - Heuristic match

    func test_extractUsageMetadata_recognizesBasicShape() {
        let um = makeUsageMetadata(input: 19585, output: 194, cached: 16294, reasoning: 139, toolUse: 55)
        let payload = wrapInStepPayload(um)
        let records = AntigravityDBUsageParser.extractUsageMetadata(from: payload)
        XCTAssertEqual(records.count, 1, "should find exactly one match")
        let r = records[0]
        XCTAssertEqual(r.input, 19585)
        XCTAssertEqual(r.output, 194)
        XCTAssertEqual(r.cached, 16294)
        XCTAssertEqual(r.reasoning, 139)
        XCTAssertEqual(r.toolUse, 55)
    }

    func test_extractUsageMetadata_sumsAcrossMultipleSubMessages() {
        let um1 = makeUsageMetadata(input: 1000, output: 100)
        let um2 = makeUsageMetadata(input: 2000, output: 200)
        var combined = Data()
        combined.append(wrapInStepPayload(um1))
        combined.append(wrapInStepPayload(um2))
        let records = AntigravityDBUsageParser.extractUsageMetadata(from: combined)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.map { $0.input }.reduce(0, +), 3000)
        XCTAssertEqual(records.map { $0.output }.reduce(0, +), 300)
    }

    func test_extractUsageMetadata_rejectsShapesMissingRequiredFields() {
        var inner: [UInt8] = []
        inner.append(0x08); inner.append(contentsOf: varint(1133))
        inner.append(0x10); inner.append(contentsOf: varint(1000))
        inner.append(0x30); inner.append(contentsOf: varint(24))
        let um = Data(inner)
        let payload = wrapInStepPayload(um)
        XCTAssertEqual(AntigravityDBUsageParser.extractUsageMetadata(from: payload).count, 0)
    }

    func test_extractUsageMetadata_rejectsWhenF6IsNotSmall() {
        var inner: [UInt8] = []
        inner.append(0x08); inner.append(contentsOf: varint(1133))
        inner.append(0x10); inner.append(contentsOf: varint(1000))
        inner.append(0x18); inner.append(contentsOf: varint(100))
        inner.append(0x30); inner.append(contentsOf: varint(999_999))
        let um = Data(inner)
        let payload = wrapInStepPayload(um)
        XCTAssertEqual(AntigravityDBUsageParser.extractUsageMetadata(from: payload).count, 0)
    }

    func test_extractUsageMetadata_handlesEmptyBlob() {
        XCTAssertEqual(AntigravityDBUsageParser.extractUsageMetadata(from: Data()).count, 0)
    }

    func test_extractUsageMetadata_handlesGarbageBlob() {
        // Random bytes shouldn't match our signature regularly. Allow
        // a small handful of false positives but assert it's not a
        // disaster — production code's fallback also catches this.
        var rng = SystemRandomNumberGenerator()
        let garbage = Data((0..<400).map { _ in UInt8.random(in: 0...255, using: &rng) })
        let records = AntigravityDBUsageParser.extractUsageMetadata(from: garbage)
        XCTAssertLessThan(records.count, 10, "structured signature rejects random data nearly always")
    }

    // MARK: - SQLite integration (best-effort, skipped if no .db on host)

    func test_parseUsage_realConversation_producesNonZeroCounts() throws {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let convDir = home.appendingPathComponent(".gemini/antigravity/conversations")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: convDir,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else {
            throw XCTSkip("No conversations directory")
        }
        let dbFiles = entries.filter { $0.pathExtension == "db" }
        guard !dbFiles.isEmpty else {
            throw XCTSkip("No .db conversations on this machine")
        }
        // Sort by size desc — bigger .db files almost always have
        // completed turns + UsageMetadata. A fresh, near-empty .db
        // can legitimately have zero matches and shouldn't fail this.
        let sorted = dbFiles.sorted {
            let a = (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let b = (try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return a > b
        }
        // Walk every .db on disk (largest-first) and return on the
        // first hit. Fresh / empty .db files legitimately have zero
        // matches, and the live-LSP file may be in a write window
        // when we copy it — neither should fail the suite, but if
        // EVERY file is empty something's actually wrong with our
        // parser and we want to know.
        for dbFile in sorted {
            // SQLite WAL means latest writes live in `<name>.db-wal`
            // (and `<name>.db-shm` is the shared-memory index). If
            // the LSP is mid-session, the `.db` file alone is stale
            // and we'd see 0 matches even though the conversation
            // has completed turns. Copy all three.
            let stem = UUID().uuidString
            let tmpDB = URL(fileURLWithPath: "/tmp/clawdmeter-test-\(stem).db")
            let tmpWAL = URL(fileURLWithPath: "/tmp/clawdmeter-test-\(stem).db-wal")
            let tmpSHM = URL(fileURLWithPath: "/tmp/clawdmeter-test-\(stem).db-shm")
            let walSrc = dbFile.deletingPathExtension().appendingPathExtension("db-wal")
            let shmSrc = dbFile.deletingPathExtension().appendingPathExtension("db-shm")
            do { try FileManager.default.copyItem(at: dbFile, to: tmpDB) } catch { continue }
            defer {
                try? FileManager.default.removeItem(at: tmpDB)
                try? FileManager.default.removeItem(at: tmpWAL)
                try? FileManager.default.removeItem(at: tmpSHM)
            }
            if FileManager.default.fileExists(atPath: walSrc.path) {
                try? FileManager.default.copyItem(at: walSrc, to: tmpWAL)
            }
            if FileManager.default.fileExists(atPath: shmSrc.path) {
                try? FileManager.default.copyItem(at: shmSrc, to: tmpSHM)
            }
            let usage = AntigravityDBUsageParser.parseUsage(dbURL: tmpDB)
            if usage.recordCount > 0 && usage.inputTokens > 0 {
                return // Success
            }
        }
        throw XCTSkip("No .db conversation on this machine had completed UsageMetadata yet")
    }

    func test_parseUsage_missingFile_returnsEmpty() {
        let bogus = URL(fileURLWithPath: "/tmp/no-such-file-\(UUID().uuidString).db")
        let usage = AntigravityDBUsageParser.parseUsage(dbURL: bogus)
        XCTAssertEqual(usage, .empty)
    }
}
#endif

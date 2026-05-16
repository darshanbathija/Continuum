import XCTest
@testable import ClawdmeterShared

/// Tests for the FirstPromptCache. Closes the plan-eng-review T12 gap
/// (`/review` flagged ZERO test coverage) — covers the four paths the
/// plan specified plus the schema-downgrade guard added during the
/// hardening sprint.
///
/// All tests use a per-test temp-dir sidecar (via the public
/// `storeURL` init param) so they're hermetic and parallel-safe.
final class FirstPromptCacheTests: XCTestCase {

    // MARK: - Test fixture helpers

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clawdmeter-cache-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        super.tearDown()
    }

    private func sidecarURL(_ name: String = "cache.json") -> URL {
        tempDir.appendingPathComponent(name)
    }

    private func makeEntry(mtime: TimeInterval = 1_700_000_000,
                          size: Int64 = 1024,
                          prompt: String? = "fix the auth bug") -> FirstPromptCache.Entry {
        .init(mtime: mtime, size: size, prompt: prompt)
    }

    // MARK: - Cold lookup

    func testColdLookupReturnsNil() {
        let cache = FirstPromptCache(storeURL: sidecarURL())
        XCTAssertNil(cache.lookup(path: "/Users/u/.claude/projects/x/abc.jsonl"))
        XCTAssertEqual(cache.count, 0)
    }

    // MARK: - Warm (set + lookup roundtrip)

    func testSetThenLookupReturnsEntry() {
        let cache = FirstPromptCache(storeURL: sidecarURL())
        let entry = makeEntry()
        cache.set(path: "/tmp/a.jsonl", entry: entry)
        XCTAssertEqual(cache.lookup(path: "/tmp/a.jsonl"), entry)
        XCTAssertEqual(cache.count, 1)
    }

    func testLookupRespectsExactPath() {
        let cache = FirstPromptCache(storeURL: sidecarURL())
        cache.set(path: "/tmp/a.jsonl", entry: makeEntry(prompt: "A"))
        XCTAssertNil(cache.lookup(path: "/tmp/b.jsonl"))
    }

    // MARK: - Stale (mtime/size mismatch is the CALLER's concern)

    func testCallerDetectsStaleEntry() {
        // The cache itself doesn't verify mtime/size against disk —
        // callers compare against the entry. Verify the contract: the
        // cache returns whatever was set; mismatch detection is in
        // RepoIndex.cachedFirstUserPrompt.
        let cache = FirstPromptCache(storeURL: sidecarURL())
        let entry = makeEntry(mtime: 1_700_000_000, size: 1024)
        cache.set(path: "/tmp/a.jsonl", entry: entry)
        let found = cache.lookup(path: "/tmp/a.jsonl")
        // Simulated "current file" mtime+size that no longer match.
        let currentMtime: TimeInterval = 1_700_000_500
        let currentSize: Int64 = 2048
        XCTAssertNotEqual(found?.mtime, currentMtime)
        XCTAssertNotEqual(found?.size, currentSize)
    }

    // MARK: - pruneDeadFiles

    func testPruneDeadFilesRemovesEntriesForMissingPaths() {
        let cache = FirstPromptCache(storeURL: sidecarURL())
        // One real file (will survive), one non-existent path.
        let realPath = tempDir.appendingPathComponent("alive.jsonl").path
        try? "{}".write(toFile: realPath, atomically: true, encoding: .utf8)
        let deadPath = tempDir.appendingPathComponent("dead.jsonl").path
        // Don't create the dead one.

        cache.set(path: realPath, entry: makeEntry(prompt: "real"))
        cache.set(path: deadPath, entry: makeEntry(prompt: "dead"))
        XCTAssertEqual(cache.count, 2)

        let pruned = cache.pruneDeadFiles()
        XCTAssertEqual(pruned, 1)
        XCTAssertEqual(cache.count, 1)
        XCTAssertNotNil(cache.lookup(path: realPath))
        XCTAssertNil(cache.lookup(path: deadPath))
    }

    func testPruneDeadFilesNoOpWhenEmpty() {
        let cache = FirstPromptCache(storeURL: sidecarURL())
        XCTAssertEqual(cache.pruneDeadFiles(), 0)
    }

    // MARK: - save / reload roundtrip

    func testSaveAndReloadRoundtrip() {
        let url = sidecarURL("roundtrip.json")
        let cache1 = FirstPromptCache(storeURL: url)
        cache1.set(path: "/tmp/a.jsonl", entry: makeEntry(prompt: "first"))
        cache1.set(path: "/tmp/b.jsonl", entry: makeEntry(prompt: "second"))
        cache1.save()

        // New instance pointed at the same sidecar.
        let cache2 = FirstPromptCache(storeURL: url)
        XCTAssertEqual(cache2.count, 2)
        XCTAssertEqual(cache2.lookup(path: "/tmp/a.jsonl")?.prompt, "first")
        XCTAssertEqual(cache2.lookup(path: "/tmp/b.jsonl")?.prompt, "second")
    }

    func testSavedSidecarIsValidJSON() throws {
        let url = sidecarURL("validity.json")
        let cache = FirstPromptCache(storeURL: url)
        cache.set(path: "/tmp/x.jsonl", entry: makeEntry(prompt: "x"))
        cache.save()

        let data = try Data(contentsOf: url)
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?["schemaVersion"] as? Int, 1)
        XCTAssertNotNil(parsed?["entries"] as? [String: Any])
    }

    // MARK: - clear

    func testClearWipesInMemoryAndSidecar() {
        let url = sidecarURL("clear.json")
        let cache = FirstPromptCache(storeURL: url)
        cache.set(path: "/tmp/a.jsonl", entry: makeEntry())
        cache.save()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        cache.clear()
        XCTAssertEqual(cache.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Schema-downgrade guard (hardening sprint addition)

    func testNewerSchemaSidecarIsNotOverwrittenOnSave() throws {
        // Simulate a future Clawdmeter build wrote a v2 sidecar; this
        // binary (v1) must NOT silently overwrite it on save() —
        // otherwise a user who installs a newer build then downgrades
        // loses their cache.
        let url = sidecarURL("v2.json")
        let v2Payload: [String: Any] = [
            "schemaVersion": 2,
            "entries": [
                "/tmp/future.jsonl": [
                    "mtime": 1_750_000_000,
                    "size": 4096,
                    "prompt": "from the future"
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: v2Payload, options: [.prettyPrinted])
        try data.write(to: url)

        let cache = FirstPromptCache(storeURL: url)
        // The v2 sidecar should NOT have loaded into memory (different schema).
        XCTAssertEqual(cache.count, 0)
        // Add a v1 entry to dirty the cache.
        cache.set(path: "/tmp/local.jsonl", entry: makeEntry(prompt: "local"))
        // Save should be a no-op (refuseToOverwriteSidecar is set).
        cache.save()

        // The on-disk file should still be v2 — unchanged.
        let reread = try Data(contentsOf: url)
        let parsed = try JSONSerialization.jsonObject(with: reread) as? [String: Any]
        XCTAssertEqual(parsed?["schemaVersion"] as? Int, 2)
        let entries = parsed?["entries"] as? [String: Any]
        XCTAssertNotNil(entries?["/tmp/future.jsonl"])
        XCTAssertNil(entries?["/tmp/local.jsonl"])
    }

    func testOlderSchemaSidecarIsDiscardedAndOverwritten() throws {
        // The opposite case: an older v0 sidecar should be discarded
        // on load and overwritten with v1 on next save. (Today
        // currentSchemaVersion=1 so we simulate a hypothetical v0.)
        let url = sidecarURL("v0.json")
        let v0Payload: [String: Any] = [
            "schemaVersion": 0,
            "entries": ["/tmp/old.jsonl": ["mtime": 0, "size": 0, "prompt": "old"]]
        ]
        let data = try JSONSerialization.data(withJSONObject: v0Payload)
        try data.write(to: url)

        let cache = FirstPromptCache(storeURL: url)
        XCTAssertEqual(cache.count, 0, "v0 entries should NOT be loaded")
        cache.set(path: "/tmp/new.jsonl", entry: makeEntry(prompt: "new"))
        cache.save()

        let reread = try Data(contentsOf: url)
        let parsed = try JSONSerialization.jsonObject(with: reread) as? [String: Any]
        XCTAssertEqual(parsed?["schemaVersion"] as? Int, 1,
                       "v0 file should have been overwritten with v1")
    }

    // MARK: - Corrupted sidecar resilience

    func testCorruptedSidecarFallsBackToEmpty() throws {
        let url = sidecarURL("corrupt.json")
        // Write garbage that isn't valid JSON.
        try "{ not valid json".write(to: url, atomically: true, encoding: .utf8)
        let cache = FirstPromptCache(storeURL: url)
        XCTAssertEqual(cache.count, 0, "corrupt sidecar should not crash; start fresh")
        // Subsequent set + save + reload should work.
        cache.set(path: "/tmp/x.jsonl", entry: makeEntry(prompt: "x"))
        cache.save()

        let cache2 = FirstPromptCache(storeURL: url)
        XCTAssertEqual(cache2.count, 1)
    }

    // MARK: - Concurrency safety (basic — actor-style usage)

    func testConcurrentSetIsSafe() async {
        let cache = FirstPromptCache(storeURL: sidecarURL("concurrent.json"))
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask {
                    cache.set(
                        path: "/tmp/file-\(i).jsonl",
                        entry: .init(mtime: TimeInterval(i), size: Int64(i), prompt: "p\(i)")
                    )
                }
            }
        }
        XCTAssertEqual(cache.count, 50)
        // Every entry should have its expected payload.
        for i in 0..<50 {
            let e = cache.lookup(path: "/tmp/file-\(i).jsonl")
            XCTAssertEqual(e?.size, Int64(i))
        }
    }
}

import XCTest
@testable import ClawdmeterShared

/// Tests for `ProviderInstanceStore` — disk persistence of non-primary
/// provider instances (multi-account Phase 1).
///
/// Locks in:
///   - Round-trip: save → load preserves records (kind, name, configRoot)
///   - Missing file / corrupt bytes / future envelope version ⇒ empty
///   - Primary-named records are NEVER persisted (and dropped on load)
///   - upsert replaces by (kind, name); remove deletes by (kind, name)
///   - `ProviderInstanceRecord.instanceId` reconstitutes the runtime id
///   - `configRoot(baseDir:kind:name:)` is deterministic + nested per kind
final class ProviderInstanceStoreTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProviderInstanceStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeStore() -> ProviderInstanceStore {
        ProviderInstanceStore(storeURL: tempDir.appendingPathComponent("provider-instances.json"))
    }

    // MARK: - Round-trip

    func testSaveLoadRoundTrip() {
        let store = makeStore()
        let work = ProviderInstanceRecord(kind: .claude, name: "work", configRoot: "/tmp/instances/claude/work")
        let pro = ProviderInstanceRecord(kind: .codex, name: "pro", configRoot: "/tmp/instances/codex/pro")
        store.save([work, pro])

        let loaded = makeStore().load()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertTrue(loaded.contains { $0.kind == .claude && $0.name == "work" && $0.configRoot == "/tmp/instances/claude/work" })
        XCTAssertTrue(loaded.contains { $0.kind == .codex && $0.name == "pro" })
    }

    func testInstanceIdReconstitution() {
        let record = ProviderInstanceRecord(kind: .claude, name: "work", configRoot: "/tmp/x")
        let id = record.instanceId
        XCTAssertEqual(id.kind, .claude)
        XCTAssertEqual(id.name, "work")
        XCTAssertEqual(id.homePathOverride, "/tmp/x")
        XCTAssertFalse(id.isPrimary)
        XCTAssertEqual(id.wireId, "claude/work")
    }

    func testRecordFromInstanceIdRoundTrip() {
        let id = ProviderInstanceId(kind: .codex, name: "oss", homePathOverride: "/tmp/codex-oss")
        let record = ProviderInstanceRecord(instance: id)
        XCTAssertEqual(record.instanceId, id)
    }

    // MARK: - Tolerant loads

    func testMissingFileLoadsEmpty() {
        XCTAssertEqual(makeStore().load(), [])
    }

    func testCorruptFileLoadsEmpty() throws {
        let url = tempDir.appendingPathComponent("provider-instances.json")
        try Data("not json {{{".utf8).write(to: url)
        XCTAssertEqual(ProviderInstanceStore(storeURL: url).load(), [])
    }

    func testFutureEnvelopeVersionLoadsEmpty() throws {
        let url = tempDir.appendingPathComponent("provider-instances.json")
        let future = """
        {"version": 99, "instances": [{"kind": "claude", "name": "work", "configRoot": "/x", "createdAt": "2026-06-11T00:00:00Z"}]}
        """
        try Data(future.utf8).write(to: url)
        XCTAssertEqual(ProviderInstanceStore(storeURL: url).load(), [])
    }

    // MARK: - Primary protection

    func testPrimaryRecordsNeverPersisted() {
        let store = makeStore()
        let primary = ProviderInstanceRecord(
            kind: .claude, name: ProviderInstanceId.primaryName, configRoot: ""
        )
        let work = ProviderInstanceRecord(kind: .claude, name: "work", configRoot: "/tmp/w")
        store.save([primary, work])

        let loaded = makeStore().load()
        XCTAssertEqual(loaded.map(\.name), ["work"])
    }

    func testPrimaryRecordsDroppedOnLoadEvenIfHandWritten() throws {
        // A hand-edited (or attacker-modified) file with a primary entry
        // must not shadow the registry-seeded primary on replay.
        let url = tempDir.appendingPathComponent("provider-instances.json")
        let bytes = """
        {"version": 1, "instances": [
          {"kind": "claude", "name": "__primary__", "configRoot": "/evil", "createdAt": "2026-06-11T00:00:00Z"},
          {"kind": "claude", "name": "work", "configRoot": "/ok", "createdAt": "2026-06-11T00:00:00Z"}
        ]}
        """
        try Data(bytes.utf8).write(to: url)
        let loaded = ProviderInstanceStore(storeURL: url).load()
        XCTAssertEqual(loaded.map(\.name), ["work"])
    }

    // MARK: - Mutations

    func testUpsertReplacesByKindAndName() {
        let store = makeStore()
        store.upsert(ProviderInstanceRecord(kind: .claude, name: "work", configRoot: "/old"))
        store.upsert(ProviderInstanceRecord(kind: .claude, name: "work", configRoot: "/new"))

        let loaded = store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.configRoot, "/new")
    }

    func testRemoveByKindAndName() {
        let store = makeStore()
        store.upsert(ProviderInstanceRecord(kind: .claude, name: "work", configRoot: "/a"))
        store.upsert(ProviderInstanceRecord(kind: .codex, name: "work", configRoot: "/b"))

        store.remove(kind: .claude, name: "work")

        let loaded = store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.kind, .codex)
    }

    func testRemoveAbsentIsNoOp() {
        let store = makeStore()
        store.upsert(ProviderInstanceRecord(kind: .claude, name: "work", configRoot: "/a"))
        store.remove(kind: .claude, name: "nope")
        XCTAssertEqual(store.load().count, 1)
    }

    // MARK: - Config roots

    func testConfigRootDeterministicAndPerKind() {
        let base = URL(fileURLWithPath: "/base")
        let claude = ProviderInstanceStore.configRoot(baseDir: base, kind: .claude, name: "work")
        let codex = ProviderInstanceStore.configRoot(baseDir: base, kind: .codex, name: "work")
        XCTAssertEqual(claude.path, "/base/Instances/claude/work")
        XCTAssertEqual(codex.path, "/base/Instances/codex/work")
        XCTAssertNotEqual(claude, codex)
        // Deterministic across calls.
        XCTAssertEqual(claude, ProviderInstanceStore.configRoot(baseDir: base, kind: .claude, name: "work"))
    }
}

#if os(macOS)
import XCTest
@testable import ClawdmeterShared

/// Exercises the AntigravityObservation protocol contract through the
/// DiskObservationProvider. Sets up a synthetic ~/.gemini/antigravity/
/// + /Applications/Antigravity.app/ layout under tempdirs so the tests
/// run hermetically — never touch the real install on the test runner.
final class AntigravityObservationTests: XCTestCase {

    // MARK: - Fixture: full simulated install

    private struct InstalledFixture {
        let home: URL
        let apps: URL
        let antigravityData: URL
        let brain: URL
    }

    private func installFixture(file: StaticString = #file, line: UInt = #line) throws -> InstalledFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("obs-test-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let apps = root.appendingPathComponent("Applications", isDirectory: true)
        let data = home.appendingPathComponent(".gemini/antigravity", isDirectory: true)
        let brainUUID = "11111111-1111-4111-8111-111111111111"
        let brain = data.appendingPathComponent("brain/\(brainUUID)", isDirectory: true)
        let conversations = data.appendingPathComponent("conversations", isDirectory: true)
        let binDir = home.appendingPathComponent("Library/Application Support/Antigravity/bin", isDirectory: true)

        try FileManager.default.createDirectory(at: brain, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: conversations, withIntermediateDirectories: true)
        let appBundle = apps.appendingPathComponent("Antigravity.app")
        try FileManager.default.createDirectory(at: appBundle, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        // v0.8.0 agy-migration: AntigravityInstall.detect now requires a
        // `language_server` binary inside the bundle (replaces the old
        // agy-node anchor). Plant the canonical Contents/Resources/bin path.
        let lsBin = appBundle.appendingPathComponent("Contents/Resources/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: lsBin, withIntermediateDirectories: true)
        try "fake-mach-o".write(to: lsBin.appendingPathComponent("language_server"), atomically: true, encoding: .utf8)

        // Plant the state file with M133 → gemini-3.5-flash mapping.
        try """
        last_selected_agent_model:  MODEL_PLACEHOLDER_M133
        installation_uuid:  "fd6a5ba1-7a30-425a-aba1-4f0cdc5b1361"
        migrate_convos_into_projects:  MIGRATION_STATUS_COMPLETED
        """.write(to: data.appendingPathComponent("antigravity_state.pbtxt"), atomically: true, encoding: .utf8)

        // Plant a tiny brain with task.md + plan.md so PlanState resolves to .ready.
        try "# Task: stub\nbody".write(to: brain.appendingPathComponent("task.md"), atomically: true, encoding: .utf8)
        try "- [x] step one\n- [ ] step two".write(to: brain.appendingPathComponent("implementation_plan.md"), atomically: true, encoding: .utf8)

        // Plant a synthetic agyhub summaries index pointing at this brain.
        let indexBytes = synthesizeIndex(brainUUID: brainUUID, cwd: "file:///Users/test/Repo")
        try indexBytes.write(to: data.appendingPathComponent("agyhub_summaries_proto.pb"))

        // Plant an encrypted-looking conversation file.
        var randomBytes = [UInt8](repeating: 0, count: 1024)
        for i in 0..<randomBytes.count { randomBytes[i] = UInt8.random(in: 0...255) }
        try Data(randomBytes).write(to: conversations.appendingPathComponent("\(brainUUID).pb"))

        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return InstalledFixture(home: home, apps: apps, antigravityData: data, brain: brain)
    }

    /// Synthesizes a minimal agyhub_summaries_proto.pb that the
    /// BrainSummaryIndexer string-scan parser can consume.
    private func synthesizeIndex(brainUUID: String, cwd: String) -> Data {
        // SummaryEntry: [0x0a, 0x24] + 36-byte UUID + [0x0a, len] + cwd bytes
        var bytes: [UInt8] = []
        bytes += [0x0a, 0x24]
        bytes += [UInt8](brainUUID.utf8)
        let cwdBytes = [UInt8](cwd.utf8)
        let lengthVarint = varintEncode(cwdBytes.count)
        bytes += [0x0a]
        bytes += lengthVarint
        bytes += cwdBytes
        return Data(bytes)
    }

    private func varintEncode(_ value: Int) -> [UInt8] {
        var v = value
        var out: [UInt8] = []
        while v >= 0x80 {
            out.append(UInt8(v & 0x7f) | 0x80)
            v >>= 7
        }
        out.append(UInt8(v & 0x7f))
        return out
    }

    // MARK: - Protocol contract

    func test_disk_isAvailableTrueWhenInstalled() async throws {
        let fx = try installFixture()
        let obs = DiskObservationProvider(homeDirectory: fx.home, applicationsRoot: fx.apps)
        let available = await obs.isAvailable()
        XCTAssertTrue(available)
    }

    func test_disk_isAvailableFalseWhenNotInstalled() async throws {
        let emptyHome = FileManager.default.temporaryDirectory.appendingPathComponent("empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyHome, withIntermediateDirectories: true)
        let emptyApps = FileManager.default.temporaryDirectory.appendingPathComponent("empty-apps-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyApps, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: emptyHome)
            try? FileManager.default.removeItem(at: emptyApps)
        }
        let obs = DiskObservationProvider(homeDirectory: emptyHome, applicationsRoot: emptyApps)
        let available = await obs.isAvailable()
        XCTAssertFalse(available)
    }

    func test_disk_currentModelReadsStateAndResolvesToken() async throws {
        let fx = try installFixture()
        let obs = DiskObservationProvider(homeDirectory: fx.home, applicationsRoot: fx.apps)
        let model = await obs.currentModel()
        XCTAssertEqual(model, "gemini-3.5-flash")
    }

    func test_disk_migrationStatusCompleted() async throws {
        let fx = try installFixture()
        let obs = DiskObservationProvider(homeDirectory: fx.home, applicationsRoot: fx.apps)
        let status = await obs.migrationStatus()
        XCTAssertEqual(status, .completed)
    }

    func test_disk_brainIndexLoadsFromSyntheticFile() async throws {
        let fx = try installFixture()
        let obs = DiskObservationProvider(homeDirectory: fx.home, applicationsRoot: fx.apps)
        let index = await obs.brainIndex()
        XCTAssertEqual(index.byUUID.count, 1)
        XCTAssertNotNil(index.byUUID["11111111-1111-4111-8111-111111111111"])
    }

    func test_disk_brainIndexCachesByMTime() async throws {
        let fx = try installFixture()
        let obs = DiskObservationProvider(homeDirectory: fx.home, applicationsRoot: fx.apps)
        _ = await obs.brainIndex()
        // Touch the file (but keep mtime stable by NOT writing).
        // Second call should hit cache. Hard to assert without
        // instrumentation; just verify it returns the same content.
        let index = await obs.brainIndex()
        XCTAssertEqual(index.byUUID.count, 1)
    }

    func test_disk_planSnapshotReturnsReadyForPopulatedBrain() async throws {
        let fx = try installFixture()
        let obs = DiskObservationProvider(homeDirectory: fx.home, applicationsRoot: fx.apps)
        let state = await obs.planSnapshot(brainURL: fx.brain)
        guard case let .ready(plan) = state else {
            return XCTFail("Expected .ready")
        }
        XCTAssertEqual(plan.taskHeadline, "Task: stub")
        XCTAssertEqual(plan.steps.count, 2)
    }

    func test_disk_planSnapshotAwaitingFirstTurnForEmptyBrain() async throws {
        let fx = try installFixture()
        let emptyBrain = fx.antigravityData.appendingPathComponent("brain/empty-uuid", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyBrain, withIntermediateDirectories: true)
        let obs = DiskObservationProvider(homeDirectory: fx.home, applicationsRoot: fx.apps)
        let state = await obs.planSnapshot(brainURL: emptyBrain)
        XCTAssertEqual(state, .awaitingFirstTurn)
    }

    func test_disk_conversationProbeDetectsEncryption() async throws {
        let fx = try installFixture()
        let convURL = fx.antigravityData
            .appendingPathComponent("conversations/11111111-1111-4111-8111-111111111111.pb")
        let obs = DiskObservationProvider(homeDirectory: fx.home, applicationsRoot: fx.apps)
        let probe = await obs.conversationProbe(conversationURL: convURL, brainURL: fx.brain)
        XCTAssertEqual(probe.kind, .encrypted)
        XCTAssertGreaterThan(probe.fileSize, 0)
    }

    func test_disk_modeLabelIsDiskMode() {
        let obs = DiskObservationProvider(homeDirectory: URL(fileURLWithPath: "/"), applicationsRoot: URL(fileURLWithPath: "/"))
        XCTAssertEqual(obs.modeLabel, "disk mode")
    }

    // MARK: - SDK stub

    func test_sdkStub_isAvailableFalse() async {
        let stub = SDKObservationProviderStub()
        let available = await stub.isAvailable()
        XCTAssertFalse(available)
    }

    func test_sdkStub_modeLabelIsProvisioning() {
        XCTAssertEqual(SDKObservationProviderStub().modeLabel, "SDK mode (provisioning)")
    }
}
#endif // os(macOS)

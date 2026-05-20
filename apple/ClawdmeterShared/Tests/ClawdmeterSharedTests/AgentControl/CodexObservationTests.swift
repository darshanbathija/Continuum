#if os(macOS)
import XCTest
@testable import ClawdmeterShared

final class CodexObservationTests: XCTestCase {

    private func makeFixture(file: StaticString = #file, line: UInt = #line) throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-obs-test-\(UUID().uuidString)", isDirectory: true)
        let sessions = home.appendingPathComponent(".codex/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return home
    }

    private func write(_ str: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try str.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Disk provider — availability

    func test_disk_isAvailableFalseWhenSessionsDirMissing() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let provider = DiskCodexObservationProvider(homeDirectory: home)
        let available = await provider.isAvailable()
        XCTAssertFalse(available)
    }

    func test_disk_isAvailableTrueWhenSessionsDirExists() async throws {
        let home = try makeFixture()
        let provider = DiskCodexObservationProvider(homeDirectory: home)
        let available = await provider.isAvailable()
        XCTAssertTrue(available)
    }

    // MARK: - Disk provider — latestUsage

    func test_disk_latestUsageNilWhenNoRollouts() async throws {
        let home = try makeFixture()
        let provider = DiskCodexObservationProvider(homeDirectory: home)
        let usage = await provider.latestUsage()
        XCTAssertNil(usage)
    }

    func test_disk_latestUsageExtractsFromSessionMeta() async throws {
        let home = try makeFixture()
        let rollout = home.appendingPathComponent(".codex/sessions/rollout-2026-05-20.jsonl")
        let line = #"{"type":"session_meta","payload":{"session_pct":47,"session_reset_mins":120,"session_epoch":1779046000}}"#
        try write(line + "\n", to: rollout)
        let provider = DiskCodexObservationProvider(homeDirectory: home)
        let usage = try await unwrapUsage(provider: provider)
        XCTAssertEqual(usage.sessionPct, 47)
        XCTAssertEqual(usage.sessionResetMins, 120)
        XCTAssertEqual(usage.sessionEpoch, 1779046000)
    }

    func test_disk_latestUsagePicksNewestRolloutByMTime() async throws {
        let home = try makeFixture()
        // Two rollouts; newer one should win.
        let older = home.appendingPathComponent(".codex/sessions/old.jsonl")
        let newer = home.appendingPathComponent(".codex/sessions/new.jsonl")
        try write(#"{"type":"session_meta","payload":{"session_pct":10,"session_reset_mins":300,"session_epoch":1779000000}}"#, to: older)
        try write(#"{"type":"session_meta","payload":{"session_pct":80,"session_reset_mins":30,"session_epoch":1779045000}}"#, to: newer)

        // Touch newer to be definitively most-recent.
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: newer.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: older.path)

        let provider = DiskCodexObservationProvider(homeDirectory: home)
        let usage = try await unwrapUsage(provider: provider)
        XCTAssertEqual(usage.sessionPct, 80, "Most-recently-modified rollout's session_meta should win")
    }

    func test_disk_modeLabelIsDiskMode() {
        XCTAssertEqual(
            DiskCodexObservationProvider(homeDirectory: URL(fileURLWithPath: "/")).modeLabel,
            "disk mode"
        )
    }

    /// Tiny helper because XCTUnwrap's autoclosure can't host an async call.
    private func unwrapUsage(provider: DiskCodexObservationProvider) async throws -> CodexUsageSnapshot {
        let value = await provider.latestUsage()
        return try XCTUnwrap(value)
    }

    // MARK: - SDK stub

    func test_sdkStub_isAvailableFalse() async {
        let stub = SDKCodexObservationProviderStub()
        let available = await stub.isAvailable()
        XCTAssertFalse(available)
    }

    func test_sdkStub_latestUsageNil() async {
        let usage = await SDKCodexObservationProviderStub().latestUsage()
        XCTAssertNil(usage)
    }

    func test_sdkStub_modeLabelIsProvisioning() {
        XCTAssertEqual(SDKCodexObservationProviderStub().modeLabel, "SDK mode (provisioning)")
    }
}
#endif // os(macOS)

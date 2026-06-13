// Coverage for the retired-tmux Claude session revival in
// AgentSessionRegistry.load(). v0.31.6 removed the tmux runtime; Claude
// sessions persisted before that upgrade still carry tmuxPaneId/tmuxWindowId,
// which made every write path surface "legacy_session_retired". The registry
// strips that dead pane metadata on load so the session routes to `.claudePty`
// and the next interaction resume-or-spawns it — no user action, no relaunch.
//
// Non-Claude legacy sessions have no cross-runtime resume path, so they keep
// their pane metadata and stay retired.
//
// The test seeds sessions.json directly (mimicking a pre-v0.31.6 snapshot) so
// the assertion exercises the JSON load path deterministically, independent of
// the orchestration event store / replay machinery.

import XCTest
import ClawdmeterShared
@testable import Clawdmeter

@MainActor
final class LegacyClaudePaneMigrationTests: XCTestCase {

    private static let eventStoreFlagKey = "com.clawdmeter.featureFlags.orchestrationEventStore"

    private var workDir: URL!
    private var sessionsURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        // Force the legacy (no-event-store) path so load() is the only thing
        // that touches the snapshot — no async replay seeding to race with.
        UserDefaults.standard.set(false, forKey: Self.eventStoreFlagKey)
        workDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clawdmeter-legacy-pane-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        sessionsURL = workDir.appendingPathComponent("sessions.json")
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: Self.eventStoreFlagKey)
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
        try await super.tearDown()
    }

    /// Write a `sessions.json` snapshot with the given session rows. Only the
    /// fields the AgentSession decoder reads need to be present; the rest
    /// default to nil/empty.
    private func writeSnapshot(_ rows: [[String: Any]]) throws {
        let iso = ISO8601DateFormatter().string(from: Date())
        let sessions = rows.map { row -> [String: Any] in
            var r = row
            r["createdAt"] = iso
            r["lastEventAt"] = iso
            r["lastEventSeq"] = 0
            r["repoDisplayName"] = r["repoDisplayName"] ?? "repo"
            r["repoKey"] = r["repoKey"] ?? "/tmp/repo"
            r["status"] = r["status"] ?? "running"
            r["mode"] = r["mode"] ?? "worktree"
            r["kind"] = r["kind"] ?? "code"
            return r
        }
        let file: [String: Any] = ["schemaVersion": 7, "sessions": sessions]
        let data = try JSONSerialization.data(withJSONObject: file)
        try data.write(to: sessionsURL)
    }

    /// A Claude session persisted with stale tmux pane metadata is revived on
    /// load (pane fields stripped); a Codex session with the same metadata is
    /// left retired.
    func test_claudePaneMetadataStrippedOnLoad_codexLeftRetired() throws {
        let claudeId = UUID()
        let codexId = UUID()
        try writeSnapshot([
            ["id": claudeId.uuidString, "agent": "claude",
             "tmuxWindowId": "@claudelegacy", "tmuxPaneId": "%claudelegacy"],
            ["id": codexId.uuidString, "agent": "codex",
             "tmuxWindowId": "@codexlegacy", "tmuxPaneId": "%codexlegacy"],
        ])

        let reg = AgentSessionRegistry(storeURL: sessionsURL, eventStore: nil)

        let claude = try XCTUnwrap(reg.session(id: claudeId))
        XCTAssertNil(claude.tmuxPaneId, "Claude pane id should be stripped on load")
        XCTAssertNil(claude.tmuxWindowId, "Claude window id should be stripped on load")
        XCTAssertTrue(SessionConfigChanger.isClaudePty(claude),
                      "Migrated Claude session must resolve as a direct PTY session")

        let codex = try XCTUnwrap(reg.session(id: codexId))
        XCTAssertEqual(codex.tmuxPaneId, "%codexlegacy", "Non-Claude legacy session stays retired")
        XCTAssertEqual(codex.tmuxWindowId, "@codexlegacy", "Non-Claude legacy session stays retired")

        // The strip is persisted once so it doesn't re-stamp lastEventAt every
        // launch: the Claude pane token is gone from disk, the Codex one remains.
        let raw = try String(contentsOf: sessionsURL, encoding: .utf8)
        XCTAssertFalse(raw.contains("%claudelegacy"), "Claude pane metadata should be persisted as stripped")
        XCTAssertTrue(raw.contains("%codexlegacy"), "Codex pane metadata should remain on disk")
    }

    /// A modern Claude PTY session (no pane metadata) loads unchanged.
    func test_modernClaudeSessionUnchanged() throws {
        let id = UUID()
        // Local mode so the orphan-provisional filter (worktree + no worktreePath
        // + no pane) doesn't drop a paneless row.
        try writeSnapshot([["id": id.uuidString, "agent": "claude", "mode": "local"]])

        let reg = AgentSessionRegistry(storeURL: sessionsURL, eventStore: nil)
        let s = try XCTUnwrap(reg.session(id: id))
        XCTAssertNil(s.tmuxPaneId)
        XCTAssertNil(s.tmuxWindowId)
        XCTAssertTrue(SessionConfigChanger.isClaudePty(s))
    }
}

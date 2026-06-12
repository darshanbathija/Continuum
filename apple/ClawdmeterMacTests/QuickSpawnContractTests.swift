import XCTest
import ClawdmeterShared
@testable import Clawdmeter

/// Locks the contract the user kept re-reporting:
/// **The per-row "+ New workspace" button must never open the New
/// Session sheet for a known repo.** That's the whole point of
/// `SessionsModel.quickSpawnInRepo(_:)` — it's the bypass.
///
/// The sheet is *only* allowed to open in two terminal cases:
///   1. The repo key isn't registered in `model.repos` (no path to
///      spawn into — sheet lets the user enter one).
///   2. The repo key is `RepoKey.other` (the non-git bucket — same
///      reason, no real path).
///
/// In every other case — including any spawn failure inside the
/// async Task — `quickSpawnInRepo` must keep `showingNewSessionSheet`
/// false and surface failures via the transient-toast channel.
@MainActor
final class QuickSpawnContractTests: XCTestCase {

    // MARK: - Test harness

    /// Bare-bones SessionsModel keyed off temp directories. Matches the
    /// pattern in `WorkspaceTabsTests.makeIsolatedModel`. The isolated model
    /// has no daemon, so any real spawn attempt fails fast — exactly what this
    /// failure-surface contract needs.
    private func makeModel(_ name: String) throws -> (SessionsModel, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let registry = AgentSessionRegistry(
            storeURL: directory.appendingPathComponent("sessions.json")
        )
        let workspaceStore = WorkspaceStore(
            storeURL: directory.appendingPathComponent("workspaces.json"),
            sessionsURL: directory.appendingPathComponent("sessions.json")
        )
        let model = SessionsModel(
            repoIndex: RepoIndex(),
            registry: registry,
            workspaceStore: workspaceStore
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (model, directory)
    }

    // MARK: - Contracts

    /// The bug the user kept re-reporting: clicking "+" on a known repo
    /// row was opening the New Session sheet instead of just spawning.
    /// Even when the underlying spawn fails (no daemon), the
    /// SHEET must stay closed — failures surface as toasts, not popups.
    func test_quickSpawnIntoKnownRepo_neverOpensSheet() async throws {
        let (model, _) = try makeModel("quickspawn-known")
        let knownKey = "/private/tmp/fake-repo-\(UUID().uuidString)"
        model.repos = [
            AgentRepo(
                key: knownKey,
                displayName: "Fake",
                hasActiveSessions: false,
                liveSessionCount: 0,
                recentSessions: []
            )
        ]

        XCTAssertFalse(model.showingNewSessionSheet)
        model.quickSpawnInRepo(knownKey)

        // Synchronous portion of quickSpawnInRepo runs to completion
        // before the async Task fires. The sheet contract is enforced
        // on the synchronous path.
        XCTAssertFalse(
            model.showingNewSessionSheet,
            "quick-spawn for a known repo must NEVER open the New Session sheet — that's the regression that keeps coming back"
        )

        // Let the async spawn Task run + fail (AppDelegate.runtime is nil in
        // tests). The contract still
        // holds: failure path must surface via toast, not the sheet.
        await Task.yield()
        await Task.yield()
        XCTAssertFalse(
            model.showingNewSessionSheet,
            "even on async spawn failure, the sheet must stay closed — failures surface as transient toasts"
        )
    }

    /// `RepoKey.other` (the non-git bucket) has no path to spawn into.
    /// Routing to the sheet IS correct here — explicitly allowed.
    func test_quickSpawnIntoOtherBucket_routesToSheetByDesign() throws {
        let (model, _) = try makeModel("quickspawn-other")
        model.repos = [
            AgentRepo(
                key: RepoKey.other,
                displayName: "Other",
                hasActiveSessions: false,
                liveSessionCount: 0,
                recentSessions: []
            )
        ]

        XCTAssertFalse(model.showingNewSessionSheet)
        model.quickSpawnInRepo(RepoKey.other)

        XCTAssertTrue(
            model.showingNewSessionSheet,
            ".other has no real path — falling back to the sheet so the user can enter one is correct"
        )
        XCTAssertEqual(model.selectedRepoKey, RepoKey.other)
    }

    /// ⌥-click "+" must open the sheet without leaving a background quick-spawn
    /// row selected. `prepareNewSession` abandons any in-flight optimistic "+"
    /// provisioning so the sheet spawn is the only active path.
    func test_prepareNewSession_abandonsInFlightQuickSpawn() throws {
        let (model, _) = try makeModel("option-click-abandon")
        let repoKey = "/private/tmp/fake-repo-\(UUID().uuidString)"
        model.repos = [
            AgentRepo(
                key: repoKey,
                displayName: "Fake",
                hasActiveSessions: false,
                liveSessionCount: 0,
                recentSessions: []
            )
        ]

        let sessionId = UUID()
        model.provisioningSessionIds.insert(sessionId)
        model.provisioningProgress[sessionId] = ProvisioningProgress()
        model.openSessionId = sessionId

        model.prepareNewSession(in: repoKey)

        XCTAssertTrue(model.showingNewSessionSheet)
        XCTAssertEqual(model.selectedRepoKey, repoKey)
        XCTAssertFalse(model.provisioningSessionIds.contains(sessionId))
        XCTAssertNil(model.provisioningProgress[sessionId])
        XCTAssertNil(model.openSessionId)
    }

    /// An unknown repo key (not in `model.repos`) also routes to the
    /// sheet — quick-spawn has nothing to spawn into.
    func test_quickSpawnIntoUnknownRepo_routesToSheet() throws {
        let (model, _) = try makeModel("quickspawn-unknown")
        // model.repos is empty — nothing is registered.
        let unknownKey = "/nope/does-not-exist"

        XCTAssertFalse(model.showingNewSessionSheet)
        model.quickSpawnInRepo(unknownKey)

        XCTAssertTrue(
            model.showingNewSessionSheet,
            "unknown repo key must fall back to the sheet so the user can pick a real path"
        )
    }
}

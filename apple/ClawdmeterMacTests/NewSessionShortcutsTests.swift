import XCTest
import ClawdmeterShared
@testable import Clawdmeter

/// REGRESSION RULE (mandatory) — T14.
///
/// The Add-Repo PR repurposes the sidebar header `folderPlus` button from
/// "New session" to "Add project (Menu)". The "New session" affordance
/// moves to `Cmd+N` (footer button) and the per-repo `+` button. These
/// tests verify both paths still set the `showingNewSessionSheet` flag +
/// the right `selectedRepoKey`, so muscle memory keeps working.
///
/// Both call sites route through `SessionsModel.prepareNewSession(in:)`,
/// so a single test target on that method covers both shortcuts.
@MainActor
final class NewSessionShortcutsTests: XCTestCase {

    private var tempDir: URL!
    private var sessionsURL: URL!
    private var workspacesURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clawdmeter-newsess-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        sessionsURL = tempDir.appendingPathComponent("sessions.json")
        workspacesURL = tempDir.appendingPathComponent("workspaces.json")
    }

    override func tearDown() async throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try await super.tearDown()
    }

    private func makeModel() -> SessionsModel {
        let registry = AgentSessionRegistry(storeURL: sessionsURL)
        let workspaceStore = WorkspaceStore(
            storeURL: workspacesURL,
            sessionsURL: sessionsURL
        )
        let repoIndex = RepoIndex()
        return SessionsModel(
            repoIndex: repoIndex,
            registry: registry,
            workspaceStore: workspaceStore
        )
    }

    /// `Cmd+N` (footer button at SessionWorkspaceView.swift:2386) calls
    /// `prepareNewSession(in: nil)` — the unscoped path that opens the
    /// New Session sheet with no preselected repo.
    func test_cmdN_path_opensNewSessionSheet_withNoPreselection() {
        let model = makeModel()
        // Sanity: starts closed.
        XCTAssertFalse(model.showingNewSessionSheet)
        XCTAssertNil(model.selectedRepoKey)
        model.prepareNewSession(in: nil)
        XCTAssertTrue(
            model.showingNewSessionSheet,
            "Cmd+N must still open the New Session sheet"
        )
        XCTAssertNil(
            model.selectedRepoKey,
            "Cmd+N must not preselect any repo"
        )
    }

    /// Per-repo `+` button (at SessionWorkspaceView.swift:1783) calls
    /// `prepareNewSession(in: repo.key)` — opens the sheet AND preselects
    /// the repo so the picker lands on the right row.
    func test_perRepoPlus_path_opensSheet_withPreselectedRepoKey() {
        let model = makeModel()
        let repoKey = "/Users/test/code/some-repo"
        XCTAssertFalse(model.showingNewSessionSheet)
        model.prepareNewSession(in: repoKey)
        XCTAssertTrue(
            model.showingNewSessionSheet,
            "Per-repo + must still open the New Session sheet"
        )
        XCTAssertEqual(
            model.selectedRepoKey,
            repoKey,
            "Per-repo + must preselect the repo key"
        )
    }

    /// Toggling the flag back to false clears the modal state. Ensures the
    /// sheet's `.onDismiss` path won't carry over stale selection.
    func test_dismissingSheet_keepsSelectionUntilExplicitlyChanged() {
        let model = makeModel()
        model.prepareNewSession(in: "/foo/bar")
        XCTAssertEqual(model.selectedRepoKey, "/foo/bar")
        // Simulate sheet dismissal: only the flag flips, selection is
        // preserved so re-opening picks up the same repo.
        model.showingNewSessionSheet = false
        XCTAssertEqual(
            model.selectedRepoKey,
            "/foo/bar",
            "selectedRepoKey must persist across explicit dismisses"
        )
    }
}

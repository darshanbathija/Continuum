import XCTest
import ClawdmeterShared
@testable import Clawdmeter

@MainActor
final class PRCoordinatorTests: XCTestCase {
    func test_snapshotMapsDaemonPRStatus() throws {
        let status = PRStatus(
            url: "https://github.com/example/repo/pull/42",
            number: 42,
            title: "Ship workbench",
            body: "Body",
            state: .open,
            additions: 12,
            deletions: 3,
            changedFiles: 4,
            reviewDecision: "APPROVED",
            checksRollup: "success"
        )

        let snapshot = try XCTUnwrap(PRCoordinator.snapshot(from: status))

        XCTAssertEqual(snapshot.url.absoluteString, "https://github.com/example/repo/pull/42")
        XCTAssertEqual(snapshot.state, "OPEN")
        XCTAssertEqual(snapshot.reviewState, "APPROVED")
        XCTAssertEqual(snapshot.checksRollup, "success")
        XCTAssertEqual(snapshot.source, .daemon)
    }

    func test_repoSlugParsesGitHubPullURL() throws {
        let url = try XCTUnwrap(URL(string: "https://github.com/example/repo/pull/42"))

        XCTAssertEqual(PRCoordinator.repoSlug(from: url), "example/repo")
    }

    func test_repoSlugRejectsNonPullOrNonGitHubURLs() throws {
        XCTAssertNil(PRCoordinator.repoSlug(from: try XCTUnwrap(URL(string: "https://evil.example/example/repo/pull/42"))))
        XCTAssertNil(PRCoordinator.repoSlug(from: try XCTUnwrap(URL(string: "https://github.com/example/repo/issues/42"))))
        XCTAssertNil(PRCoordinator.repoSlug(from: try XCTUnwrap(URL(string: "http://github.com/example/repo/pull/42"))))
    }

    func test_approvalIdentityRejectsURLNumberMismatch() throws {
        let snapshot = PRCoordinator.Snapshot(
            url: try XCTUnwrap(URL(string: "https://github.com/example/repo/pull/99")),
            number: 42,
            title: "Ship workbench",
            state: "OPEN",
            author: "octo",
            additions: 1,
            deletions: 1,
            body: "",
            reviewState: nil,
            checksRollup: "success",
            checks: [],
            lastChecked: Date(),
            source: .daemon
        )

        XCTAssertNil(PRCoordinator.approvalIdentity(for: snapshot))
    }

    // MARK: - daemonDisowned fallback (v0.30)

    /// A daemon returning `.sessionUnknown` (HTTP 404) flips
    /// `daemonDisowned`, stops daemon polling, and hands the pane to
    /// `PRMirror`. Verifies the fix that stopped synthetic preview
    /// sessions from pinning "Daemon returned HTTP 404" forever.
    func test_daemonReturningSessionUnknown_flipsToFallback() async throws {
        let stubClient = StubPRClient()
        stubClient.outcomes = [.sessionUnknown]
        let mirror = PRMirror(sessionId: UUID())
        let coordinator = PRCoordinator(
            sessionId: UUID(),
            client: stubClient,
            fallback: mirror
        )

        XCTAssertTrue(coordinator.canUseDaemonActions, "fresh coordinator with a daemon client should expose daemon actions")
        XCTAssertNil(coordinator.snapshot)
        XCTAssertNil(coordinator.lastError)

        await coordinator.refreshDaemonOnce()

        XCTAssertFalse(coordinator.canUseDaemonActions, "after .sessionUnknown, canUseDaemonActions should be false so the UI hides Create/Merge")
        XCTAssertNil(coordinator.lastError, ".sessionUnknown is a normal state — must NOT surface as a user-facing error")
        XCTAssertEqual(stubClient.getOutcomeCalls, 1)

        // A second refresh after disown short-circuits — no further daemon hits.
        await coordinator.refreshDaemonOnce()
        XCTAssertEqual(stubClient.getOutcomeCalls, 1, "daemon should NOT be polled again after disown")
    }

    /// Happy path: daemon returns `.found(status)` → snapshot mirrors it,
    /// daemonDisowned stays false.
    func test_daemonReturningFound_setsSnapshotAndKeepsDaemonActions() async throws {
        let status = PRStatus(
            url: "https://github.com/example/repo/pull/7",
            number: 7,
            title: "Hello",
            body: "",
            state: .open,
            additions: 1,
            deletions: 0,
            changedFiles: 1,
            reviewDecision: nil,
            checksRollup: "success"
        )
        let stubClient = StubPRClient()
        stubClient.outcomes = [.found(status)]
        let mirror = PRMirror(sessionId: UUID())
        let coordinator = PRCoordinator(
            sessionId: UUID(),
            client: stubClient,
            fallback: mirror
        )

        await coordinator.refreshDaemonOnce()

        XCTAssertNotNil(coordinator.snapshot)
        XCTAssertEqual(coordinator.snapshot?.number, 7)
        XCTAssertEqual(coordinator.snapshot?.source, .daemon)
        XCTAssertTrue(coordinator.canUseDaemonActions)
    }

    /// `.noPR` clears any stale snapshot and lastError without disowning.
    /// The daemon knows the session, it just has no PR yet.
    func test_daemonReturningNoPR_clearsSnapshotWithoutDisowning() async throws {
        let stubClient = StubPRClient()
        stubClient.outcomes = [.noPR]
        let mirror = PRMirror(sessionId: UUID())
        let coordinator = PRCoordinator(
            sessionId: UUID(),
            client: stubClient,
            fallback: mirror
        )

        await coordinator.refreshDaemonOnce()

        XCTAssertNil(coordinator.snapshot)
        XCTAssertNil(coordinator.lastError)
        XCTAssertTrue(coordinator.canUseDaemonActions, "noPR is a known-session state; daemon actions stay live")
    }

    /// `.unavailable(message)` surfaces the message as `lastError` so the
    /// pane shows what went wrong. Daemon stays in play — could be a
    /// transient gh-not-installed / network blip.
    func test_daemonReturningUnavailable_surfacesError() async throws {
        let stubClient = StubPRClient()
        stubClient.outcomes = [.unavailable("gh not found")]
        let mirror = PRMirror(sessionId: UUID())
        let coordinator = PRCoordinator(
            sessionId: UUID(),
            client: stubClient,
            fallback: mirror
        )

        await coordinator.refreshDaemonOnce()

        XCTAssertNil(coordinator.snapshot)
        XCTAssertEqual(coordinator.lastError, "gh not found")
        XCTAssertTrue(coordinator.canUseDaemonActions)
    }

    func test_canMergeRequiresKnownPassingChecks() throws {
        let base = PRCoordinator.Snapshot(
            url: try XCTUnwrap(URL(string: "https://github.com/example/repo/pull/42")),
            number: 42,
            title: "Ship workbench",
            state: "OPEN",
            author: "octo",
            additions: 1,
            deletions: 1,
            body: "",
            reviewState: nil,
            checksRollup: "success",
            checks: [],
            lastChecked: Date(),
            source: .daemon
        )

        XCTAssertTrue(PRCoordinator.canMerge(snapshot: base, canUseDaemonActions: true))
        let unknown = PRCoordinator.Snapshot(
            url: base.url,
            number: base.number,
            title: base.title,
            state: base.state,
            author: base.author,
            additions: base.additions,
            deletions: base.deletions,
            body: base.body,
            reviewState: base.reviewState,
            checksRollup: nil,
            checks: [],
            lastChecked: base.lastChecked,
            source: base.source
        )
        XCTAssertTrue(PRCoordinator.canMerge(snapshot: unknown, canUseDaemonActions: true))
        XCTAssertFalse(PRCoordinator.canMerge(snapshot: base, canUseDaemonActions: false))
    }

    /// merge() success path: a daemon merge that returns ok writes the fresh
    /// snapshot and leaves no stale error. The trailing refreshDaemonOnce()
    /// no-ops because merge set a non-nil snapshot and we're not watching, so
    /// the post-merge state is deterministic.
    func test_merge_successWritesSnapshotAndClearsError() async throws {
        let stub = StubPRClient()
        stub.mergeResult = MergePRResponse(
            ok: true,
            merged: true,
            pr: PRStatus(
                url: "https://github.com/example/repo/pull/7", number: 7,
                title: "Ship it", body: "", state: .open, additions: 2, deletions: 1,
                changedFiles: 1, reviewDecision: "APPROVED", checksRollup: "success"
            ),
            receipt: nil,
            error: nil
        )
        let coordinator = PRCoordinator(sessionId: UUID(), client: stub, fallback: PRMirror(sessionId: UUID()))

        await coordinator.merge()

        XCTAssertEqual(stub.mergeCalls, 1)
        XCTAssertEqual(coordinator.snapshot?.number, 7)
        XCTAssertNil(coordinator.lastError)
    }
}

// MARK: - Test stubs

/// Hand-rolled stub conforming to `PRCoordinatingClient`. Replays a queued
/// list of `PRStatusOutcome` values so each refresh call gets a different
/// answer; counts calls so tests can assert "the daemon was NOT polled
/// again after disown."
@MainActor
private final class StubPRClient: PRCoordinatingClient {
    var lastError: String?
    var outcomes: [AgentControlClient.PRStatusOutcome] = []
    var getOutcomeCalls = 0
    var mergeResult: MergePRResponse?
    var mergeCalls = 0

    func getPRStatus(sessionId: UUID) async -> PRStatus? {
        switch await getPRStatusOutcome(sessionId: sessionId) {
        case .found(let status): return status
        default: return nil
        }
    }

    func getPRStatusOutcome(sessionId: UUID) async -> AgentControlClient.PRStatusOutcome {
        getOutcomeCalls += 1
        if outcomes.isEmpty { return .unavailable("stub exhausted") }
        return outcomes.removeFirst()
    }

    func createPR(
        sessionId: UUID,
        title: String?,
        body: String?,
        baseBranch: String?,
        idempotencyKey: String?
    ) async -> String? { nil }

    func merge(
        sessionId: UUID,
        method: PRMergeMethod,
        deleteBranch: Bool,
        auto: Bool,
        adminOverride: Bool,
        idempotencyKey: String?
    ) async -> MergePRResponse? {
        mergeCalls += 1
        return mergeResult
    }
}

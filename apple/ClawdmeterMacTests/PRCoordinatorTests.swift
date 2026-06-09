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

    func test_prCompactPaneEmptyActionsExposeStableTargets() {
        let daemonBacked = TahoePRCompactPane.emptyActionDescriptors(canUseDaemonActions: true)

        XCTAssertEqual(TahoePRCompactPane.EmptyActionDescriptors.rootAccessibilityIdentifier, "code.pr.empty")
        XCTAssertEqual(TahoePRCompactPane.EmptyActionDescriptors.manualURLAccessibilityIdentifier, "code.pr.manual-url")
        XCTAssertEqual(daemonBacked.load.title, "Load")
        XCTAssertEqual(daemonBacked.load.accessibilityIdentifier, "code.pr.load")
        XCTAssertEqual(daemonBacked.create?.title, "Create PR")
        XCTAssertEqual(daemonBacked.create?.accessibilityIdentifier, "code.pr.create")
        XCTAssertEqual(daemonBacked.draft?.title, "Draft PR")
        XCTAssertEqual(daemonBacked.draft?.accessibilityIdentifier, "code.pr.draft")

        let fallbackOnly = TahoePRCompactPane.emptyActionDescriptors(canUseDaemonActions: false)
        XCTAssertNil(fallbackOnly.create)
        XCTAssertNil(fallbackOnly.draft)
    }

    func test_prCompactPaneLoadedActionsGateRerunAndMerge() throws {
        let snapshot = try makeSnapshot(checks: [
            PRCheckMirror(
                name: "Unit tests",
                state: .failure,
                url: "https://github.com/example/repo/actions/runs/987654321"
            ),
            PRCheckMirror(name: "Lint", state: .success, url: nil)
        ])

        let menu = TahoePRCompactPane.actionMenuDescriptors(for: snapshot)
        XCTAssertEqual(TahoePRCompactPane.ActionMenuDescriptors.menuAccessibilityIdentifier, "code.pr.actions")
        XCTAssertEqual(menu.openGitHub.accessibilityIdentifier, "code.pr.open-github")
        XCTAssertEqual(menu.openChecks.accessibilityIdentifier, "code.pr.open-checks")
        XCTAssertEqual(menu.openDeployments.accessibilityIdentifier, "code.pr.open-deployments")
        XCTAssertEqual(menu.copyURL.accessibilityIdentifier, "code.pr.copy-url")
        XCTAssertEqual(menu.copyNumber.accessibilityIdentifier, "code.pr.copy-number")
        XCTAssertEqual(menu.rerunFailedChecks.accessibilityIdentifier, "code.pr.rerun-failed-checks")
        XCTAssertTrue(menu.rerunFailedChecks.isEnabled)
        XCTAssertEqual(menu.askAgentToFixChecks.accessibilityIdentifier, "code.pr.ask-agent-fix-checks")
        XCTAssertEqual(TahoePRCompactPane.failedCheckRunIDs(in: snapshot), ["987654321"])

        let mergeReady = TahoePRCompactPane.reviewActionDescriptors(
            for: snapshot,
            canUseDaemonActions: true,
            todoGatePassed: true
        )
        XCTAssertEqual(mergeReady?.approve.accessibilityIdentifier, "code.pr.approve")
        XCTAssertEqual(mergeReady?.requestChanges.accessibilityIdentifier, "code.pr.request-changes")
        XCTAssertEqual(mergeReady?.merge.title, "Merge")
        XCTAssertEqual(mergeReady?.merge.accessibilityIdentifier, "code.pr.merge")
        XCTAssertEqual(mergeReady?.merge.isEnabled, true)

        let todoBlocked = TahoePRCompactPane.reviewActionDescriptors(
            for: snapshot,
            canUseDaemonActions: true,
            todoGatePassed: false
        )
        XCTAssertEqual(todoBlocked?.merge.title, "Merge blocked")
        XCTAssertEqual(todoBlocked?.merge.isEnabled, false)
        XCTAssertNil(TahoePRCompactPane.reviewActionDescriptors(
            for: snapshot,
            canUseDaemonActions: false,
            todoGatePassed: true
        ))
    }

    func test_prCompactPaneStatusAndCheckDescriptorsExposeStableTargets() throws {
        let status = TahoePRCompactPane.statusRowDescriptor(
            key: "ci",
            title: "ci",
            status: "success",
            passed: true
        )
        XCTAssertEqual(status.accessibilityIdentifier, "code.pr.status.ci")
        XCTAssertEqual(status.status, "success")
        XCTAssertTrue(status.passed)

        let failingCheck = PRCheckMirror(
            name: "Build",
            state: .failure,
            url: "https://github.com/example/repo/actions/runs/12345"
        )
        let check = TahoePRCompactPane.checkRowDescriptor(failingCheck)
        XCTAssertEqual(TahoePRCompactPane.CheckRowDescriptor.rowAccessibilityIdentifier, "code.pr.check.row")
        XCTAssertEqual(check.name, "Build")
        XCTAssertEqual(check.state, "failure")
        XCTAssertEqual(check.open?.accessibilityIdentifier, "code.pr.check.open")
        XCTAssertEqual(check.copyName.accessibilityIdentifier, "code.pr.check.copy-name")
        XCTAssertEqual(check.rerun?.accessibilityIdentifier, "code.pr.check.rerun")
        XCTAssertEqual(TahoePRCompactPane.runID(from: failingCheck.url), "12345")

        let missingURL = TahoePRCompactPane.checkRowDescriptor(PRCheckMirror(name: "Docs", state: .success))
        XCTAssertNil(missingURL.open)
        XCTAssertNil(missingURL.rerun)
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

    func test_createPR_failurePreservesActionErrorAndDoesNotRefreshAwayOutcome() async throws {
        let stub = StubPRClient()
        stub.outcomes = [.found(makeStatus(number: 7))]
        let coordinator = PRCoordinator(sessionId: UUID(), client: stub, fallback: PRMirror(sessionId: UUID()))

        await coordinator.createPR()

        XCTAssertEqual(stub.createPRCalls, 1)
        XCTAssertEqual(stub.getOutcomeCalls, 0, "A failed create action must not refresh and clear the user-visible action error.")
        XCTAssertEqual(coordinator.lastError, "Create PR failed")
        XCTAssertNil(coordinator.snapshot)
    }

    func test_merge_failurePreservesActionErrorAndDoesNotRefreshAwayOutcome() async throws {
        let stub = StubPRClient()
        stub.outcomes = [.found(makeStatus(number: 7))]
        stub.mergeResult = MergePRResponse(
            ok: false,
            merged: false,
            pr: nil,
            receipt: nil,
            error: "Branch protection blocked merge"
        )
        let coordinator = PRCoordinator(sessionId: UUID(), client: stub, fallback: PRMirror(sessionId: UUID()))

        await coordinator.merge()

        XCTAssertEqual(stub.mergeCalls, 1)
        XCTAssertEqual(stub.getOutcomeCalls, 0, "A failed merge action must keep the daemon error visible instead of immediately refreshing it away.")
        XCTAssertEqual(coordinator.lastError, "Branch protection blocked merge")
        XCTAssertNil(coordinator.snapshot)
    }

    func test_approve_runsGitHubReviewAndSurfacesFailureThenClearsOnSuccess() async throws {
        let stub = StubPRClient()
        stub.outcomes = [.found(makeStatus(number: 7, reviewDecision: nil))]
        let runner = StubShellRunner(results: [
            ShellRunner.Result(exitStatus: 1, stdout: Data(), stderr: Data("denied\n".utf8)),
            ShellRunner.Result(exitStatus: 0, stdout: Data(), stderr: Data())
        ])
        let coordinator = PRCoordinator(
            sessionId: UUID(),
            client: stub,
            fallback: PRMirror(sessionId: UUID()),
            runner: runner,
            ghLocator: { "/usr/bin/gh" }
        )
        await coordinator.refreshDaemonOnce()

        await coordinator.approve()

        XCTAssertEqual(coordinator.lastError, "approve failed: denied\n")
        var calls = await runner.recordedCalls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].executable, "/usr/bin/gh")
        XCTAssertEqual(calls[0].arguments, ["pr", "review", "--approve", "7", "--repo", "example/repo"])
        XCTAssertEqual(calls[0].timeout, 30)

        await coordinator.approve()

        XCTAssertNil(coordinator.lastError)
        calls = await runner.recordedCalls()
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[1].arguments, ["pr", "review", "--approve", "7", "--repo", "example/repo"])
    }

    func test_approve_reportsParseErrorWithoutRunningGh() async throws {
        let stub = StubPRClient()
        stub.outcomes = [.found(makeStatus(url: "https://github.com/example/repo/pull/99", number: 7))]
        let runner = StubShellRunner()
        let coordinator = PRCoordinator(
            sessionId: UUID(),
            client: stub,
            fallback: PRMirror(sessionId: UUID()),
            runner: runner,
            ghLocator: { "/usr/bin/gh" }
        )
        await coordinator.refreshDaemonOnce()

        await coordinator.approve()

        XCTAssertEqual(coordinator.lastError, "couldn't parse PR URL")
        let calls = await runner.recordedCalls()
        XCTAssertEqual(calls.count, 0)
    }

    func test_approve_reportsMissingGhWithoutRunningShell() async throws {
        let stub = StubPRClient()
        stub.outcomes = [.found(makeStatus(number: 7))]
        let runner = StubShellRunner()
        let coordinator = PRCoordinator(
            sessionId: UUID(),
            client: stub,
            fallback: PRMirror(sessionId: UUID()),
            runner: runner,
            ghLocator: { () -> String? in nil }
        )
        await coordinator.refreshDaemonOnce()

        await coordinator.approve()

        XCTAssertEqual(coordinator.lastError, "gh not found — install GitHub CLI")
        let calls = await runner.recordedCalls()
        XCTAssertEqual(calls.count, 0)
    }

    private func makeSnapshot(
        url rawURL: String = "https://github.com/example/repo/pull/42",
        number: Int = 42,
        state: String = "OPEN",
        reviewState: String? = "APPROVED",
        checksRollup: String? = "success",
        checks: [PRCheckMirror] = []
    ) throws -> PRCoordinator.Snapshot {
        PRCoordinator.Snapshot(
            url: try XCTUnwrap(URL(string: rawURL)),
            number: number,
            title: "Ship workbench",
            state: state,
            author: "octo",
            additions: 1,
            deletions: 1,
            body: "",
            reviewState: reviewState,
            checksRollup: checksRollup,
            checks: checks,
            lastChecked: Date(),
            source: .daemon
        )
    }

    private func makeStatus(
        url: String = "https://github.com/example/repo/pull/7",
        number: Int = 7,
        title: String = "Ship it",
        state: PRStatus.State = .open,
        reviewDecision: String? = "APPROVED",
        checksRollup: String? = "success"
    ) -> PRStatus {
        PRStatus(
            url: url,
            number: number,
            title: title,
            body: "",
            state: state,
            additions: 2,
            deletions: 1,
            changedFiles: 1,
            reviewDecision: reviewDecision,
            checksRollup: checksRollup
        )
    }
}

final class ReviewPaneContentDescriptorTests: XCTestCase {
    func test_sourcesPaneDescriptorsCapRowsAndExposeStableTargets() {
        var entries: [SourceEntry] = (0..<16).map { index in
            SourceEntry(
                id: "f:\(index)",
                kind: .file,
                label: "File\(index).swift",
                payload: "/repo/File\(index).swift",
                count: index == 0 ? 1 : index
            )
        }
        entries.insert(SourceEntry(
            id: "u:docs",
            kind: .url,
            label: "Docs",
            payload: "https://example.com/docs",
            count: 4
        ), at: 1)

        let descriptors = TahoeSourcesPreviewPane.sourceRowDescriptors(from: entries)

        XCTAssertEqual(descriptors.count, TahoeSourcesPreviewPane.maxVisibleEntries)
        XCTAssertEqual(TahoeSourcesPreviewPane.paneAccessibilityIdentifier, "code.sources.pane")
        XCTAssertEqual(TahoeSourcesPreviewPane.emptyAccessibilityIdentifier, "code.sources.empty")
        XCTAssertEqual(TahoeSourcesPreviewPane.rowAccessibilityIdentifier, "code.sources.row")

        XCTAssertEqual(descriptors[0].accessibilityIdentifier, "code.sources.row")
        XCTAssertEqual(descriptors[0].label, "File0.swift")
        XCTAssertEqual(descriptors[0].subtitle, "Referenced 1x")
        XCTAssertNil(descriptors[0].counterText)
        XCTAssertEqual(descriptors[0].accessibilityValue, "file: /repo/File0.swift")

        XCTAssertEqual(descriptors[1].kind, .url)
        XCTAssertEqual(descriptors[1].icon, "link")
        XCTAssertEqual(descriptors[1].subtitle, "Fetched URL")
        XCTAssertEqual(descriptors[1].counterText, "×4")
        XCTAssertEqual(descriptors[1].accessibilityValue, "url: https://example.com/docs")
        XCTAssertEqual(descriptors.last?.label, "File12.swift")
    }

    func test_artifactsPaneDescriptorExposesStableTargets() {
        let artifact = ArtifactsPane.Artifact(
            path: "/tmp/continuum-output/report.pdf",
            url: URL(fileURLWithPath: "/tmp/continuum-output/report.pdf")
        )

        let descriptor = ArtifactsPane.artifactDescriptor(for: artifact)

        XCTAssertEqual(ArtifactsPane.paneAccessibilityIdentifier, "code.artifacts.pane")
        XCTAssertEqual(ArtifactsPane.emptyAccessibilityIdentifier, "code.artifacts.empty")
        XCTAssertEqual(ArtifactsPane.gridAccessibilityIdentifier, "code.artifacts.grid")
        XCTAssertEqual(ArtifactsPane.cardAccessibilityIdentifier, "code.artifacts.card")
        XCTAssertEqual(ArtifactsPane.thumbnailAccessibilityIdentifier, "code.artifacts.thumbnail")
        XCTAssertEqual(ArtifactsPane.previewAccessibilityIdentifier, "code.artifacts.preview")
        XCTAssertEqual(ArtifactsPane.previewCloseAccessibilityIdentifier, "code.artifacts.preview.close")
        XCTAssertEqual(descriptor.filename, "report.pdf")
        XCTAssertEqual(descriptor.path, "/tmp/continuum-output/report.pdf")
        XCTAssertEqual(descriptor.accessibilityIdentifier, "code.artifacts.card")
        XCTAssertEqual(descriptor.accessibilityValue, "/tmp/continuum-output/report.pdf")
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
    var createPRResult: String?
    var createPRCalls = 0
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
    ) async -> String? {
        createPRCalls += 1
        return createPRResult
    }

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

private actor StubShellRunner: ShellRunning {
    struct Call: Equatable, Sendable {
        let executable: String
        let arguments: [String]
        let cwd: String?
        let environment: [String: String]?
        let timeout: TimeInterval
    }

    private var results: [ShellRunner.Result]
    private var calls: [Call] = []

    init(results: [ShellRunner.Result] = []) {
        self.results = results
    }

    func run(
        executable: String,
        arguments: [String],
        cwd: String?,
        environment: [String: String]?,
        timeout: TimeInterval
    ) async throws -> ShellRunner.Result {
        calls.append(Call(
            executable: executable,
            arguments: arguments,
            cwd: cwd,
            environment: environment,
            timeout: timeout
        ))
        if results.isEmpty {
            return ShellRunner.Result(exitStatus: 0, stdout: Data(), stderr: Data())
        }
        return results.removeFirst()
    }

    func recordedCalls() -> [Call] {
        calls
    }
}

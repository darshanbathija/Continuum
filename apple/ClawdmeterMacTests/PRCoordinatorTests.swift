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
}

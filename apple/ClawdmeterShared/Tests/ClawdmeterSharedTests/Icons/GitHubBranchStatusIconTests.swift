import XCTest
@testable import ClawdmeterShared

final class GitHubBranchStatusIconTests: XCTestCase {
    func testPreferredStatePriority() {
        XCTAssertEqual(
            GitHubBranchIconKind.preferred(from: [.closed, .open]),
            .pullRequestOpen
        )
        XCTAssertEqual(
            GitHubBranchIconKind.preferred(from: [.closed, .merged, .draft]),
            .pullRequestDraft
        )
        XCTAssertEqual(
            GitHubBranchIconKind.preferred(from: [.closed, .merged]),
            .pullRequestMerged
        )
        XCTAssertEqual(
            GitHubBranchIconKind.preferred(from: [.closed]),
            .pullRequestClosed
        )
        XCTAssertEqual(GitHubBranchIconKind.preferred(from: []), .branch)
    }

    func testFromRawState() {
        XCTAssertEqual(GitHubBranchIconKind.from(prStateRaw: "OPEN"), .pullRequestOpen)
        XCTAssertEqual(GitHubBranchIconKind.from(prStateRaw: "merged"), .pullRequestMerged)
        XCTAssertEqual(GitHubBranchIconKind.from(prStateRaw: "closed"), .pullRequestClosed)
        XCTAssertEqual(GitHubBranchIconKind.from(prStateRaw: nil), .branch)
    }

    func testAssetNamesMatchOcticons() {
        XCTAssertEqual(GitHubBranchIconKind.branch.assetName, "github-octicon-git-branch")
        XCTAssertEqual(GitHubBranchIconKind.pullRequestOpen.assetName, "github-octicon-git-pull-request")
        XCTAssertEqual(GitHubBranchIconKind.pullRequestClosed.assetName, "github-octicon-git-pull-request-closed")
        XCTAssertEqual(GitHubBranchIconKind.pullRequestMerged.assetName, "github-octicon-git-merge")
    }
}

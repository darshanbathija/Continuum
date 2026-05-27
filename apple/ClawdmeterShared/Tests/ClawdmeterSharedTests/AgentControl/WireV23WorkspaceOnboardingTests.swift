import XCTest
@testable import ClawdmeterShared

/// Wire v23 — workspace onboarding (Add Repo flow) tests.
///
/// Verifies:
///   - `AgentControlWireVersion.current >= 23` and `workspaceOnboardingMinimum = 23`.
///   - `supportsWorkspaceOnboarding` capability gate behaves correctly.
///   - Prior minimums unchanged (regression).
///   - Codable round-trip for the 5 new DTOs and `RepoOnboardingError` across
///     every case (including associated values).
///   - `MobileCommandKind` gains the 4 new workspace-onboarding cases.
final class WireV23WorkspaceOnboardingTests: XCTestCase {

    // MARK: - Wire version + capability gate

    func test_currentWireVersionIsAtLeast23() {
        XCTAssertGreaterThanOrEqual(AgentControlWireVersion.current, 23)
    }

    func test_workspaceOnboardingMinimumIs23() {
        XCTAssertEqual(AgentControlWireVersion.workspaceOnboardingMinimum, 23)
    }

    func test_supportsWorkspaceOnboarding_falseBelow23() {
        XCTAssertFalse(AgentControlWireVersion.supportsWorkspaceOnboarding(serverWireVersion: 22))
        XCTAssertFalse(AgentControlWireVersion.supportsWorkspaceOnboarding(serverWireVersion: 16))
        XCTAssertFalse(AgentControlWireVersion.supportsWorkspaceOnboarding(serverWireVersion: 1))
        XCTAssertFalse(AgentControlWireVersion.supportsWorkspaceOnboarding(serverWireVersion: nil))
    }

    func test_supportsWorkspaceOnboarding_trueAt23AndAbove() {
        XCTAssertTrue(AgentControlWireVersion.supportsWorkspaceOnboarding(serverWireVersion: 23))
        XCTAssertTrue(AgentControlWireVersion.supportsWorkspaceOnboarding(serverWireVersion: 24))
        XCTAssertTrue(AgentControlWireVersion.supportsWorkspaceOnboarding(serverWireVersion: 100))
    }

    func test_priorMinimumsUnchanged() {
        XCTAssertEqual(AgentControlWireVersion.composeDraftMinimum, 4)
        XCTAssertEqual(AgentControlWireVersion.chatSubscribeMinimum, 5)
        XCTAssertEqual(AgentControlWireVersion.geminiMinimum, 6)
        XCTAssertEqual(AgentControlWireVersion.antigravityMinimum, 7)
        XCTAssertEqual(AgentControlWireVersion.codexSDKMinimum, 8)
        XCTAssertEqual(AgentControlWireVersion.chatMinimum, 9)
        XCTAssertEqual(AgentControlWireVersion.frontierMinimum, 9)
        XCTAssertEqual(AgentControlWireVersion.codexChatBackendMinimum, 9)
        XCTAssertEqual(AgentControlWireVersion.agentapiMinimum, 10)
        XCTAssertEqual(AgentControlWireVersion.antigravityChatMinimum, 11)
        XCTAssertEqual(AgentControlWireVersion.turnLifecycleMinimum, 14)
        XCTAssertEqual(AgentControlWireVersion.deepResearchMinimum, 14)
        XCTAssertEqual(AgentControlWireVersion.chatSearchMinimum, 14)
        XCTAssertEqual(AgentControlWireVersion.codeV2Minimum, 15)
        XCTAssertEqual(AgentControlWireVersion.workspacesMinimum, 16)
        XCTAssertEqual(AgentControlWireVersion.mobileOutboxMinimum, 16)
        XCTAssertEqual(AgentControlWireVersion.cursorMinimum, 17)
        XCTAssertEqual(AgentControlWireVersion.codeWorkbenchRemoteMinimum, 18)
        XCTAssertEqual(AgentControlWireVersion.lifecycleMinimum, 19)
        XCTAssertEqual(AgentControlWireVersion.providerDefaultsMinimum, 19)
        XCTAssertEqual(AgentControlWireVersion.providerInstanceMinimum, 20)
        XCTAssertEqual(AgentControlWireVersion.shellDetailMinimum, 21)
        XCTAssertEqual(AgentControlWireVersion.tabContextMinimum, 22)
    }

    // MARK: - DTO Codable round-trips

    func test_openLocalFolderRequest_roundTrip() throws {
        let req = OpenLocalFolderRequest(idempotencyKey: "abc-123")
        let data = try JSONEncoder().encode(req)
        let decoded = try JSONDecoder().decode(OpenLocalFolderRequest.self, from: data)
        XCTAssertEqual(decoded.idempotencyKey, "abc-123")

        let emptyReq = OpenLocalFolderRequest()
        let emptyData = try JSONEncoder().encode(emptyReq)
        let emptyDecoded = try JSONDecoder().decode(OpenLocalFolderRequest.self, from: emptyData)
        XCTAssertNil(emptyDecoded.idempotencyKey)
    }

    func test_cloneFromGitHubRequest_roundTrip() throws {
        let req = CloneFromGitHubRequest(
            spec: "anthropics/claude-code-sdk",
            destinationParent: "/Users/x/code",
            idempotencyKey: "clone-xyz"
        )
        let data = try JSONEncoder().encode(req)
        let decoded = try JSONDecoder().decode(CloneFromGitHubRequest.self, from: data)
        XCTAssertEqual(decoded.spec, "anthropics/claude-code-sdk")
        XCTAssertEqual(decoded.destinationParent, "/Users/x/code")
        XCTAssertEqual(decoded.idempotencyKey, "clone-xyz")
    }

    func test_cloneFromGitHubRequest_optionalDestinationDecodes() throws {
        let json = #"{"spec":"foo/bar"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(CloneFromGitHubRequest.self, from: json)
        XCTAssertEqual(decoded.spec, "foo/bar")
        XCTAssertNil(decoded.destinationParent)
        XCTAssertNil(decoded.idempotencyKey)
    }

    func test_quickStartRepoRequest_roundTrip() throws {
        let req = QuickStartRepoRequest(
            name: "scratchpad",
            parent: "/Users/x/code",
            idempotencyKey: "qs-1"
        )
        let data = try JSONEncoder().encode(req)
        let decoded = try JSONDecoder().decode(QuickStartRepoRequest.self, from: data)
        XCTAssertEqual(decoded.name, "scratchpad")
        XCTAssertEqual(decoded.parent, "/Users/x/code")
        XCTAssertEqual(decoded.idempotencyKey, "qs-1")
    }

    func test_wakeMacRequest_roundTrip() throws {
        let req = WakeMacRequest(idempotencyKey: "wake-1")
        let data = try JSONEncoder().encode(req)
        let decoded = try JSONDecoder().decode(WakeMacRequest.self, from: data)
        XCTAssertEqual(decoded.idempotencyKey, "wake-1")
    }

    func test_workspaceAllowListResponse_roundTrip() throws {
        let resp = WorkspaceAllowListResponse(
            allowedRoots: ["/Users/x/code", "/Volumes/Code"],
            deniedSubpaths: ["~/.ssh", "~/.aws", "~/Library", "~/.config", "~/Public"]
        )
        let data = try JSONEncoder().encode(resp)
        let decoded = try JSONDecoder().decode(WorkspaceAllowListResponse.self, from: data)
        XCTAssertEqual(decoded.allowedRoots, ["/Users/x/code", "/Volumes/Code"])
        XCTAssertEqual(decoded.deniedSubpaths.count, 5)
    }

    // MARK: - RepoOnboardingError round-trips (every case)

    func test_repoOnboardingError_pathMissing_roundTrip() throws {
        try roundTrip(.pathMissing)
    }

    func test_repoOnboardingError_notADirectory_roundTrip() throws {
        try roundTrip(.notADirectory)
    }

    func test_repoOnboardingError_alreadyRegistered_roundTrip() throws {
        let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        try roundTrip(.alreadyRegistered(workspaceId: id))
    }

    func test_repoOnboardingError_notAGitRepo_roundTrip() throws {
        try roundTrip(.notAGitRepo)
    }

    func test_repoOnboardingError_ghAuthFailed_roundTrip() throws {
        try roundTrip(.ghAuthFailed)
    }

    func test_repoOnboardingError_cloneFailed_roundTrip() throws {
        try roundTrip(.cloneFailed(stderr: "fatal: repository not found"))
    }

    func test_repoOnboardingError_gitInitFailed_roundTrip() throws {
        try roundTrip(.gitInitFailed(stderr: "error: could not initialize"))
    }

    func test_repoOnboardingError_persistenceFailed_roundTrip() throws {
        try roundTrip(.persistenceFailed(message: "disk full"))
    }

    func test_repoOnboardingError_pathNotAllowed_roundTrip() throws {
        try roundTrip(.pathNotAllowed(reason: "outside allow-list"))
    }

    // MARK: - MobileCommandKind extension

    func test_mobileCommandKind_includesNewWorkspaceOnboardingCases() {
        XCTAssertEqual(MobileCommandKind.openLocalFolder.rawValue, "open_local_folder")
        XCTAssertEqual(MobileCommandKind.cloneFromGitHub.rawValue, "clone_from_github")
        XCTAssertEqual(MobileCommandKind.quickStartRepo.rawValue, "quick_start_repo")
        XCTAssertEqual(MobileCommandKind.wakeMac.rawValue, "wake_mac")
    }

    func test_mobileCommandKind_roundTrip_workspaceOnboardingCases() throws {
        for kind in [
            MobileCommandKind.openLocalFolder,
            .cloneFromGitHub,
            .quickStartRepo,
            .wakeMac,
        ] {
            let data = try JSONEncoder().encode(kind)
            let decoded = try JSONDecoder().decode(MobileCommandKind.self, from: data)
            XCTAssertEqual(decoded, kind, "MobileCommandKind.\(kind) should round-trip")
        }
    }

    // MARK: - Helpers

    private func roundTrip(_ error: RepoOnboardingError, file: StaticString = #file, line: UInt = #line) throws {
        let data = try JSONEncoder().encode(error)
        let decoded = try JSONDecoder().decode(RepoOnboardingError.self, from: data)
        XCTAssertEqual(decoded, error, "RepoOnboardingError did not round-trip cleanly", file: file, line: line)
    }
}

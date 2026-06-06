import XCTest
import ClawdmeterShared
@testable import Clawdmeter

/// Verifies DaemonChatStoreRegistry's default URL resolver stays conservative:
/// Claude may use its cwd-scoped project-dir resolver, while providers without
/// a proven session path do not fall back to global provider history.
@MainActor
final class DaemonChatStoreRegistryRoutingTests: XCTestCase {

    private func makeSession(
        agent: AgentKind,
        runtimeBinding: SessionRuntimeBinding? = nil
    ) -> AgentSession {
        AgentSession(
            id: UUID(),
            repoKey: "/Users/test/Repo",
            repoDisplayName: "Repo",
            agent: agent,
            model: nil,
            goal: nil,
            worktreePath: nil,
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            status: .running,
            planText: nil,
            createdAt: Date(),
            lastEventAt: Date(),
            lastEventSeq: 1,
            mode: .local,
            runtimeBinding: runtimeBinding
        )
    }

    func test_defaultResolveURL_geminiFailsClosedWithoutOwnedPath() {
        let session = makeSession(agent: .gemini)
        XCTAssertNil(DaemonChatStoreRegistry.defaultResolveURL(sessionId: session.id, session: session))
    }

    func test_defaultResolveURL_claudeSessionsUnchangedByAGYBranching() {
        let session = makeSession(agent: .claude)
        // Claude path still goes through SessionChatStore.resolveSessionFileURL
        // — no regression from the agentapi branch.
        _ = DaemonChatStoreRegistry.defaultResolveURL(sessionId: session.id, session: session)
    }

    func test_claudePtyCodeSessionRolloverUsesResolverWithoutLegacyPane() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daemon-chat-rollover-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let firstURL = dir.appendingPathComponent("first.jsonl")
        let secondURL = dir.appendingPathComponent("second.jsonl")
        try "{}\n".write(to: firstURL, atomically: true, encoding: .utf8)
        try "{}\n".write(to: secondURL, atomically: true, encoding: .utf8)

        var resolvedURL = firstURL
        let registry = DaemonChatStoreRegistry(resolveURL: { _, _ in resolvedURL })
        let session = makeSession(agent: .claude)

        let firstStore = try XCTUnwrap(registry.snapshotStore(for: session))
        XCTAssertEqual(firstStore.currentFileURL, firstURL)

        resolvedURL = secondURL
        let secondStore = try XCTUnwrap(registry.snapshotStore(for: session))
        XCTAssertEqual(secondStore.currentFileURL, secondURL)
    }

    func test_codexAppServerSessionUsesPersistedHarnessRuntimeNotGlobalFlag() throws {
        var resolverCallCount = 0
        let registry = DaemonChatStoreRegistry(resolveURL: { _, _ in
            resolverCallCount += 1
            return URL(fileURLWithPath: "/tmp/unrelated-codex.jsonl")
        })
        let session = makeSession(
            agent: .codex,
            runtimeBinding: SessionRuntimeBinding(runtimeKind: .codexAppServer)
        )

        let store = try XCTUnwrap(registry.snapshotStore(for: session))

        XCTAssertTrue(store.isSDKOnly)
        XCTAssertEqual(resolverCallCount, 0, "bridge-fed Codex app-server sessions must not fall back to JSONL resolution")
    }

    // MARK: - v0.23.2 T8: opencode branch routing

    func test_defaultResolveURL_opencodeFailsClosedWithoutOwnedPath() {
        // OpenCode sessions have no JSONL rollout file — the registry's
        // createStore branch instantiates an sdkOnly SessionChatStore and
        // never asks defaultResolveURL for a path.
        let session = makeSession(agent: .opencode)
        XCTAssertNil(DaemonChatStoreRegistry.defaultResolveURL(sessionId: session.id, session: session))
    }
}

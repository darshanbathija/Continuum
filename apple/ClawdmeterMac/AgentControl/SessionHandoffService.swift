import Foundation
import ClawdmeterShared

public enum SessionHandoffError: Error, Equatable {
    case sessionNotFound
    case targetHostUnknown
    case targetHostUnreachable
    case gitDirty(String)
    case gitPushFailed(String)
    case remoteSpawnFailed(String)
}

struct GitRepositorySnapshot: Sendable, Equatable {
    let remoteURL: String?
    let branch: String?
    let commit: String?
}

enum GitRepositorySnapshotResolver {
    static func resolve(cwd: String) async -> GitRepositorySnapshot? {
        guard let git = ShellRunner.locateBinary("git") else { return nil }
        async let remote = runGit(git: git, cwd: cwd, arguments: ["config", "--get", "remote.origin.url"])
        async let branch = runGit(git: git, cwd: cwd, arguments: ["rev-parse", "--abbrev-ref", "HEAD"])
        async let commit = runGit(git: git, cwd: cwd, arguments: ["rev-parse", "HEAD"])
        let resolvedRemote = await remote
        let resolvedBranch = await branch
        let resolvedCommit = await commit
        if resolvedRemote == nil && resolvedBranch == nil && resolvedCommit == nil {
            return nil
        }
        return GitRepositorySnapshot(
            remoteURL: resolvedRemote,
            branch: resolvedBranch == "HEAD" ? nil : resolvedBranch,
            commit: resolvedCommit
        )
    }

    private static func runGit(git: String, cwd: String, arguments: [String]) async -> String? {
        guard let result = try? await ShellRunner.shared.run(
            executable: git,
            arguments: arguments,
            cwd: cwd,
            timeout: 15
        ) else { return nil }
        let trimmed = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// D1/D9 handoff: push branch, spawn linked session on target host.
@MainActor
public final class SessionHandoffService {

    private let registry: AgentSessionRegistry
    private let hostStore: ExecutionHostStore
    private let coordinator: ExecutionHostCoordinator

    public init(
        registry: AgentSessionRegistry,
        hostStore: ExecutionHostStore = .shared,
        coordinator: ExecutionHostCoordinator
    ) {
        self.registry = registry
        self.hostStore = hostStore
        self.coordinator = coordinator
    }

    public func handoff(
        sessionId: UUID,
        targetHostId: UUID,
        clientOnTailnet: Bool = false
    ) async throws -> HandoffSessionResponse {
        guard let source = registry.session(id: sessionId) else {
            throw SessionHandoffError.sessionNotFound
        }
        guard let targetHost = hostStore.host(id: targetHostId) else {
            throw SessionHandoffError.targetHostUnknown
        }
        guard targetHost.kind != .localMac else {
            throw SessionHandoffError.remoteSpawnFailed("Pick a remote device, not this Mac.")
        }
        let route = coordinator.route(for: targetHostId, clientOnTailnet: clientOnTailnet)
        switch route {
        case .remoteDirect, .remoteRelay:
            break
        default:
            throw SessionHandoffError.targetHostUnreachable
        }

        let sourceHostId = source.executionHostId ?? hostStore.localHostIdValue()
        try await registry.updateHandoff(
            id: sessionId,
            handoff: HandoffState(
                targetHostId: targetHostId,
                sourceHostId: sourceHostId,
                phase: .pushingBranch,
                startedAt: Date()
            )
        )
        Self.broadcastHandoffPhase(sessionId: sessionId, phase: .pushingBranch)

        let cwd = source.effectiveCwd
        try await assertCleanGitState(cwd: cwd)
        try await pushCurrentBranch(cwd: cwd)
        guard let sourceGit = await GitRepositorySnapshotResolver.resolve(cwd: cwd),
              let sourceRemoteURL = sourceGit.remoteURL,
              !sourceRemoteURL.isEmpty
        else {
            throw SessionHandoffError.remoteSpawnFailed("Remote handoff requires a git origin URL for the source repo.")
        }

        try await registry.updateHandoff(
            id: sessionId,
            handoff: HandoffState(
                targetHostId: targetHostId,
                sourceHostId: sourceHostId,
                phase: .spawningRemote,
                startedAt: Date()
            )
        )
        Self.broadcastHandoffPhase(sessionId: sessionId, phase: .spawningRemote)

        if targetHost.kind == .byocAWS {
            try await AWSCloudIdleMonitor.shared.ensureRunning(
                host: targetHost,
                provisioner: AWSComputeProvisioner(hostStore: hostStore)
            )
        }

        let repoKey = source.repoKey ?? cwd
        let newSession = try await coordinator.forwardSessionCreate(
            hostId: targetHostId,
            request: NewSessionRequest(
                repoKey: repoKey,
                agent: source.agent,
                model: source.model,
                planMode: source.status == .planning,
                goal: source.goal,
                useWorktree: source.worktreePath != nil,
                effort: source.effort,
                providerInstanceId: source.providerInstanceId,
                customProviderId: source.customProviderId,
                targetHostId: targetHostId,
                parentSessionId: sessionId,
                sourceRemoteURL: sourceRemoteURL,
                sourceBranch: sourceGit.branch,
                sourceCommit: sourceGit.commit
            ),
            clientOnTailnet: clientOnTailnet
        )

        try await registry.updateHandoff(
            id: sessionId,
            handoff: HandoffState(
                targetHostId: targetHostId,
                sourceHostId: sourceHostId,
                phase: .attached,
                startedAt: Date()
            )
        )
        try await registry.archive(id: sessionId)
        Self.broadcastHandoffPhase(sessionId: sessionId, phase: .attached)

        return HandoffSessionResponse(
            sourceSessionId: sessionId,
            newSessionId: newSession.id,
            targetHostId: targetHostId
        )
    }

    private func assertCleanGitState(cwd: String) async throws {
        guard let git = ShellRunner.locateBinary("git") else { return }
        let status = try await ShellRunner.shared.run(
            executable: git,
            arguments: ["status", "--porcelain"],
            cwd: cwd,
            timeout: 15
        )
        let trimmed = status.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            throw SessionHandoffError.gitDirty("Commit or stash changes before handoff.")
        }
    }

    private func pushCurrentBranch(cwd: String) async throws {
        guard let git = ShellRunner.locateBinary("git") else { return }
        let branchResult = try await ShellRunner.shared.run(
            executable: git,
            arguments: ["rev-parse", "--abbrev-ref", "HEAD"],
            cwd: cwd,
            timeout: 10
        )
        let branch = branchResult.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty, branch != "HEAD" else { return }
        do {
            _ = try await ShellRunner.shared.run(
                executable: git,
                arguments: ["push", "-u", "origin", branch],
                cwd: cwd,
                timeout: 120
            )
        } catch let error as ShellRunner.ShellError {
            throw SessionHandoffError.gitPushFailed(error.localizedDescription)
        }
    }

    private static func broadcastHandoffPhase(sessionId: UUID, phase: HandoffState.Phase) {
        AgentEventStream.recordEvent(
            sessionId: sessionId,
            kind: .handoffPhaseChanged,
            payload: [
                "sessionId": sessionId.uuidString,
                "phase": phase.rawValue
            ]
        )
    }
}

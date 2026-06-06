import Foundation
import ClawdmeterShared
import OSLog

private let swapLogger = Logger(subsystem: "com.clawdmeter.mac", category: "SessionConfigChanger")

/// Mid-session config swap helper. Handles model / effort / mode / plan-code
/// changes for direct Claude PTY sessions. Legacy pane-backed sessions are
/// retired and are not respawned.
@MainActor
public final class SessionConfigChanger {

    public enum SwapResult: Sendable {
        case swapped(newPaneId: String)
        case resumeFailed(restoredOriginal: Bool)
        case spawnError(message: String)
    }

    private let registry: AgentSessionRegistry
    private let repoEnvResolver: RepoEnvRuntimeResolver?

    public init(
        registry: AgentSessionRegistry,
        repoEnvResolver: RepoEnvRuntimeResolver? = nil
    ) {
        self.registry = registry
        self.repoEnvResolver = repoEnvResolver
    }

    /// Swap one or more config dimensions on a live session.
    ///
    /// `newModel` / `newEffort` / `newPlanMode` / `newMode` are all optional;
    /// each `nil` means "keep current."
    @discardableResult
    public func swap(
        sessionId: UUID,
        newModel: String? = nil,
        newEffort: ReasoningEffort?? = nil,
        newPlanMode: Bool? = nil,
        newMode: SessionMode? = nil
    ) async -> SwapResult {
        guard let session = registry.session(id: sessionId) else {
            return .spawnError(message: "Session not found")
        }
        // Claude PTY sessions swap via the PTY registry: suspend + respawn with
        // the persisted claudeSessionId.
        if Self.isClaudePty(session) {
            return await swapPty(session: session, newModel: newModel, newEffort: newEffort, newPlanMode: newPlanMode, newMode: newMode)
        }
        return .spawnError(message: "legacy_session_retired")
    }

    /// Revive a degraded direct Claude PTY session.
    @discardableResult
    public func revive(sessionId: UUID) async -> SwapResult {
        guard let session = registry.session(id: sessionId) else {
            return .spawnError(message: "Session not found")
        }
        // Track A: revive a Claude PTY session via the registry.
        if Self.isClaudePty(session) {
            return await revivePty(session: session)
        }
        return .spawnError(message: "legacy_session_retired")
    }

    // MARK: - Claude PTY swap / revive

    /// True when this session is a Claude PTY session (no legacy pane fields).
    static func isClaudePty(_ s: AgentSession) -> Bool {
        s.agent == .claude && s.tmuxPaneId == nil && s.tmuxWindowId == nil
    }

    /// Mode/model/effort swap for a Claude PTY session: apply the new config to
    /// the registry, suspend the old host, then respawn. `AgentSpawner.argv(for:)`
    /// reads the updated config AND appends `--resume <claudeSessionId>` (T7/T8),
    /// so the conversation continues.
    private func swapPty(
        session: AgentSession,
        newModel: String?,
        newEffort: ReasoningEffort??,
        newPlanMode: Bool?,
        newMode: SessionMode?
    ) async -> SwapResult {
        let sessionId = session.id
        let cwd: String
        switch newMode ?? session.mode {
        case .local:    cwd = session.repoKey ?? session.effectiveCwd
        case .worktree: cwd = session.effectiveCwd
        case .cloud:    cwd = session.repoKey ?? session.effectiveCwd
        }
        // Env preflight before touching the running host.
        let resolvedRepoEnv: [String: String]?
        do { resolvedRepoEnv = try repoEnvResolver?.resolveForLaunch(session: session, cwd: cwd)?.environment }
        catch { return .spawnError(message: error.localizedDescription) }
        do { try await registry.updateStatus(id: sessionId, status: .paused) }
        catch { return .spawnError(message: "Failed to record paused state: \(error.localizedDescription)") }
        AgentEventStream.recordEvent(sessionId: sessionId, kind: .statusChanged,
                                     payload: ["status": "paused", "reason": "config-swap-pty"])
        // Apply new config FIRST so argv(for:) reads it on respawn.
        if let newModel { try? await registry.setModel(id: sessionId, model: newModel, effort: newEffort ?? session.effort) }
        if let actualEffort = newEffort.flatMap({ $0 }) { try? await registry.setEffort(id: sessionId, effort: actualEffort) }
        if let newPlanMode { try? await registry.setPlanMode(id: sessionId, planMode: newPlanMode) }
        await ClaudePtyRegistry.shared.suspend(sessionId)
        guard let updated = registry.session(id: sessionId) else {
            return .spawnError(message: "Session vanished mid-swap")
        }
        let argv = AgentSpawner.argv(for: updated, autopilot: AutopilotState.shared.isEnabled(sessionId: sessionId))
        guard !argv.isEmpty else {
            try? await registry.updateStatus(id: sessionId, status: .degraded)
            return .spawnError(message: "Could not locate agent binary on PATH")
        }
        do {
            let env = AgentSpawner.claudePtyEnv(extra: resolvedRepoEnv)
            _ = try await ClaudePtyRegistry.shared.resumeOrSpawn(id: sessionId, plan: { ClaudePtyRegistry.SpawnPlan(argv: argv, cwd: cwd, env: env) })
            try await registry.updateRuntime(id: sessionId, worktreePath: session.worktreePath,
                                             runtimeCwd: .some(cwd), tmuxWindowId: nil, tmuxPaneId: nil,
                                             mode: newMode ?? session.mode)
            try await registry.updateStatus(id: sessionId, status: .running)
            AgentEventStream.recordEvent(sessionId: sessionId, kind: .statusChanged,
                                         payload: ["status": "running", "reason": "config-swap-pty-complete"])
            return .swapped(newPaneId: "")   // PTY sessions have no legacy pane id
        } catch {
            swapLogger.error("PTY swap failed for \(sessionId.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            try? await registry.updateStatus(id: sessionId, status: .degraded)
            return .resumeFailed(restoredOriginal: false)
        }
    }

    /// Revive a degraded Claude PTY session: drop any stale host + respawn with
    /// the same config (+ `--resume`).
    private func revivePty(session: AgentSession) async -> SwapResult {
        let sessionId = session.id
        let cwd: String
        switch session.mode {
        case .local:    cwd = session.repoKey ?? session.effectiveCwd
        case .worktree: cwd = session.effectiveCwd
        case .cloud:    cwd = session.repoKey ?? session.effectiveCwd
        }
        let resolvedRepoEnv: [String: String]?
        do { resolvedRepoEnv = try repoEnvResolver?.resolveForLaunch(session: session, cwd: cwd)?.environment }
        catch { return .spawnError(message: error.localizedDescription) }
        await ClaudePtyRegistry.shared.suspend(sessionId)
        let argv = AgentSpawner.argv(for: session, autopilot: AutopilotState.shared.isEnabled(sessionId: sessionId))
        guard !argv.isEmpty else { return .spawnError(message: "Could not locate agent binary on PATH") }
        do {
            let env = AgentSpawner.claudePtyEnv(extra: resolvedRepoEnv)
            _ = try await ClaudePtyRegistry.shared.resumeOrSpawn(id: sessionId, plan: { ClaudePtyRegistry.SpawnPlan(argv: argv, cwd: cwd, env: env) })
            try await registry.updateRuntime(id: sessionId, worktreePath: session.worktreePath,
                                             runtimeCwd: .some(cwd), tmuxWindowId: nil, tmuxPaneId: nil,
                                             mode: session.mode)
            try await registry.updateStatus(id: sessionId, status: .running)
            AgentEventStream.recordEvent(sessionId: sessionId, kind: .statusChanged,
                                         payload: ["status": "running", "reason": "revive-pty"])
            return .swapped(newPaneId: "")
        } catch {
            try? await registry.updateStatus(id: sessionId, status: .degraded)
            return .spawnError(message: error.localizedDescription)
        }
    }

}

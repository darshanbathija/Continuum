import Foundation
import ClawdmeterShared
import OSLog

private let swapLogger = Logger(subsystem: "com.clawdmeter.mac", category: "SessionConfigChanger")

/// Mid-session config swap helper. Unifies the kill-existing-pane +
/// respawn-with-new-config flow that handles model / effort / mode /
/// plan-code changes. Wraps the D13 overlay UX from `SessionWorkspaceView`.
///
/// Phase 1 from Sessions v2 (T32 spec for state machine):
/// - Mark session as paused, broadcast statusChanged event
/// - Kill the current tmux pane
/// - Respawn with new argv (claude --resume <id> + new model/effort flags,
///   or codex resume <id>)
/// - Validate the new pane actually came up (D12 resume-fail detection)
/// - On failure: kill the new pane, re-spawn with the original config
@MainActor
public final class SessionConfigChanger {

    public enum SwapResult: Sendable {
        case swapped(newPaneId: String)
        case resumeFailed(restoredOriginal: Bool)
        case spawnError(message: String)
    }

    private let registry: AgentSessionRegistry
    private let tmux: TmuxControlClient
    private let repoEnvResolver: RepoEnvRuntimeResolver?

    public init(
        registry: AgentSessionRegistry,
        tmux: TmuxControlClient,
        repoEnvResolver: RepoEnvRuntimeResolver? = nil
    ) {
        self.registry = registry
        self.tmux = tmux
        self.repoEnvResolver = repoEnvResolver
    }

    /// Swap one or more config dimensions on a live session.
    ///
    /// `newModel` / `newEffort` / `newPlanMode` / `newMode` are all optional;
    /// each `nil` means "keep current." Tmux pane is killed-then-respawned
    /// in the same window so the user sees the existing window with new
    /// content. D13 overlay covers the visual gap.
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
        // Track A: a Claude PTY session has no tmux pane — swap via the PTY
        // registry (suspend + respawn with the persisted claudeSessionId), not
        // kill-pane + tmux.newWindow.
        if Self.isClaudePty(session) {
            return await swapPty(session: session, newModel: newModel, newEffort: newEffort, newPlanMode: newPlanMode, newMode: newMode)
        }
        guard let oldPaneId = session.tmuxPaneId ?? session.tmuxWindowId else {
            return .spawnError(message: "Session not found or has no pane")
        }
        // Cursor swaps go through the ACP bridge, not this tmux respawn path —
        // only Claude/Codex CLI reach here.
        let providerResumeId = sessionId.uuidString
        let originalArgv = AgentSpawner.respawnArgv(
            agent: session.agent,
            resumeSessionId: providerResumeId,
            model: session.model,
            planMode: session.status == .planning,
            effort: session.effort,
            autopilot: AutopilotState.shared.isEnabled(sessionId: sessionId),
            acceptEdits: PermissionModeStore.shared.acceptEdits(sessionId: sessionId),
            workspacePath: session.effectiveCwd
        )
        let newArgv = AgentSpawner.respawnArgv(
            agent: session.agent,
            resumeSessionId: providerResumeId,
            model: newModel ?? session.model,
            planMode: newPlanMode ?? (session.status == .planning),
            effort: (newEffort == nil ? session.effort : newEffort!),
            autopilot: AutopilotState.shared.isEnabled(sessionId: sessionId),
            acceptEdits: PermissionModeStore.shared.acceptEdits(sessionId: sessionId),
            workspacePath: session.effectiveCwd
        )
        if newArgv.isEmpty {
            return .spawnError(message: "Could not locate agent binary on PATH")
        }
        // v0.24 env preflight: resolve before touching the running pane. A
        // manual .env.local conflict should fail the swap, not kill the session.
        let cwd: String
        switch newMode ?? session.mode {
        case .local:    cwd = session.repoKey ?? session.effectiveCwd
        case .worktree: cwd = session.effectiveCwd
        case .cloud:    cwd = session.repoKey ?? session.effectiveCwd
        }
        let newEnv: [String: String]
        do {
            newEnv = try repoEnvResolver?.resolveForLaunch(session: session, cwd: cwd)?.environment ?? [:]
        } catch {
            return .spawnError(message: error.localizedDescription)
        }
        // F2-wire: write-ahead failures during config swap can fail the
        // swap outright — the user invoked this synchronously through
        // the UI overlay, so a clean "swap failed, original preserved"
        // path is preferable to a half-mutated session in memory.
        do {
            try await registry.updateStatus(id: sessionId, status: .paused)
        } catch {
            swapLogger.error("updateStatus(.paused) write-ahead failed: \(error.localizedDescription, privacy: .public)")
            return .spawnError(message: "Failed to record paused state: \(error.localizedDescription)")
        }
        AgentEventStream.recordEvent(
            sessionId: sessionId,
            kind: .statusChanged,
            payload: ["status": "paused", "reason": "config-swap"]
        )
        do {
            try await tmux.killPane(oldPaneId)
            let newWindow = try await tmux.newWindow(cwd: cwd, child: newArgv, environment: newEnv)
            try await registry.updateRuntime(
                id: sessionId,
                worktreePath: session.worktreePath,
                runtimeCwd: .some(cwd),
                tmuxWindowId: newWindow.windowId,
                tmuxPaneId: newWindow.paneId,
                mode: newMode ?? session.mode
            )
            if let newModel { try await registry.setModel(id: sessionId, model: newModel, effort: newEffort ?? session.effort) }
            if let actualEffort = newEffort.flatMap({ $0 }) { try await registry.setEffort(id: sessionId, effort: actualEffort) }
            if let newPlanMode { try await registry.setPlanMode(id: sessionId, planMode: newPlanMode) }
            try await registry.updateStatus(id: sessionId, status: .running)
            AgentEventStream.recordEvent(
                sessionId: sessionId,
                kind: .statusChanged,
                payload: ["status": "running", "reason": "config-swap-complete"]
            )
            return .swapped(newPaneId: newWindow.paneId)
        } catch {
            swapLogger.error("Swap failed for session \(sessionId.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            // D12 resume-fail rescue: try to restore original config in the same window.
            do {
                let env = try repoEnvResolver?.resolveForLaunch(
                    session: session,
                    cwd: session.effectiveCwd
                )?.environment ?? [:]
                let restoreWindow = try await tmux.newWindow(
                    cwd: session.effectiveCwd,
                    child: originalArgv,
                    environment: env
                )
                try await registry.updateRuntime(
                    id: sessionId,
                    worktreePath: session.worktreePath,
                    runtimeCwd: .some(session.effectiveCwd),
                    tmuxWindowId: restoreWindow.windowId,
                    tmuxPaneId: restoreWindow.paneId,
                    mode: session.mode
                )
                try await registry.updateStatus(id: sessionId, status: .running)
                return .resumeFailed(restoredOriginal: true)
            } catch {
                // Last-ditch: mark degraded. Don't propagate further —
                // surface a structured result so the caller can render
                // an error overlay.
                do {
                    try await registry.updateStatus(id: sessionId, status: .degraded)
                } catch {
                    swapLogger.error("updateStatus(.degraded) write-ahead failed during rescue: \(error.localizedDescription, privacy: .public)")
                }
                return .resumeFailed(restoredOriginal: false)
            }
        }
    }

    /// Revive a degraded session whose tmux pane died — the tmux server
    /// restarted (e.g. app relaunch) and reassigned pane ids, leaving the
    /// session's recorded `tmuxPaneId` stale. Respawns the agent into a FRESH
    /// window with the SAME config + `--resume`, then updates the registry's
    /// pane ids + status so the terminal can reconnect to a live shell.
    ///
    /// Unlike `swap`, this skips `kill-pane` when the old pane is already gone
    /// (kill-pane on a missing target throws) and returns a clean result
    /// instead of routing through swap's resume-fail rescue branch.
    @discardableResult
    public func revive(sessionId: UUID) async -> SwapResult {
        guard let session = registry.session(id: sessionId) else {
            return .spawnError(message: "Session not found")
        }
        // Track A: revive a Claude PTY session via the registry.
        if Self.isClaudePty(session) {
            return await revivePty(session: session)
        }
        // Cursor revive goes through the ACP bridge, not this tmux respawn path.
        let providerResumeId = sessionId.uuidString
        let argv = AgentSpawner.respawnArgv(
            agent: session.agent,
            resumeSessionId: providerResumeId,
            model: session.model,
            planMode: session.status == .planning,
            effort: session.effort,
            autopilot: AutopilotState.shared.isEnabled(sessionId: sessionId),
            acceptEdits: PermissionModeStore.shared.acceptEdits(sessionId: sessionId),
            workspacePath: session.effectiveCwd
        )
        if argv.isEmpty {
            return .spawnError(message: "Could not locate agent binary on PATH")
        }
        let cwd: String
        switch session.mode {
        case .local:    cwd = session.repoKey ?? session.effectiveCwd
        case .worktree: cwd = session.effectiveCwd
        case .cloud:    cwd = session.repoKey ?? session.effectiveCwd
        }
        let env: [String: String]
        do {
            env = try repoEnvResolver?.resolveForLaunch(session: session, cwd: cwd)?.environment ?? [:]
        } catch {
            return .spawnError(message: error.localizedDescription)
        }
        // Kill the stale pane only if it still exists. A degraded session's
        // recorded pane is usually already gone (server restart), and
        // kill-pane on a missing target throws — which we don't want to treat
        // as a revive failure.
        if let oldPaneId = session.tmuxPaneId ?? session.tmuxWindowId,
           await Self.paneExists(oldPaneId, tmux: tmux) {
            try? await tmux.killPane(oldPaneId)
        }
        do {
            let newWindow = try await tmux.newWindow(cwd: cwd, child: argv, environment: env)
            try await registry.updateRuntime(
                id: sessionId,
                worktreePath: session.worktreePath,
                runtimeCwd: .some(cwd),
                tmuxWindowId: newWindow.windowId,
                tmuxPaneId: newWindow.paneId,
                mode: session.mode
            )
            try await registry.updateStatus(id: sessionId, status: .running)
            AgentEventStream.recordEvent(
                sessionId: sessionId,
                kind: .statusChanged,
                payload: ["status": "running", "reason": "revive"]
            )
            return .swapped(newPaneId: newWindow.paneId)
        } catch {
            swapLogger.error("Revive failed for session \(sessionId.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            try? await registry.updateStatus(id: sessionId, status: .degraded)
            return .spawnError(message: error.localizedDescription)
        }
    }

    /// Cheap liveness probe: does `paneId` still exist on the tmux server?
    /// `list-panes -t <id>` throws when the pane is gone.
    private static func paneExists(_ paneId: String, tmux: TmuxControlClient) async -> Bool {
        do { _ = try await tmux.command(["list-panes", "-t", paneId]); return true }
        catch { return false }
    }

    // MARK: - Track A: Claude PTY swap / revive

    /// True when this session is a Claude PTY session (flag on, no tmux pane).
    /// Reads the flag at call time so a mid-session flip is honored.
    static func isClaudePty(_ s: AgentSession) -> Bool {
        UserDefaults.standard.bool(forKey: "clawdmeter.claude.ptyHost.enabled")
            && s.agent == .claude && s.tmuxPaneId == nil && s.tmuxWindowId == nil
    }

    /// Mode/model/effort swap for a Claude PTY session: apply the new config to
    /// the registry, suspend the old host, then respawn. `AgentSpawner.argv(for:)`
    /// reads the updated config AND appends `--resume <claudeSessionId>` (T7/T8),
    /// so the conversation continues — no tmux pane involved.
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
        // Env preflight before touching the running host (parity with tmux path).
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
            return .swapped(newPaneId: "")   // PTY sessions have no tmux pane
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

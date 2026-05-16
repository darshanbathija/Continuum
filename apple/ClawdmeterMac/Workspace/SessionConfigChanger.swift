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

    public init(registry: AgentSessionRegistry, tmux: TmuxControlClient) {
        self.registry = registry
        self.tmux = tmux
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
        guard let session = registry.session(id: sessionId),
              let oldPaneId = session.tmuxPaneId ?? session.tmuxWindowId else {
            return .spawnError(message: "Session not found or has no pane")
        }
        let originalArgv = AgentSpawner.respawnArgv(
            agent: session.agent,
            resumeSessionId: sessionId.uuidString,
            model: session.model,
            planMode: session.status == .planning,
            effort: session.effort,
            autopilot: AutopilotState.shared.isEnabled(sessionId: sessionId)
        )
        let newArgv = AgentSpawner.respawnArgv(
            agent: session.agent,
            resumeSessionId: sessionId.uuidString,
            model: newModel ?? session.model,
            planMode: newPlanMode ?? (session.status == .planning),
            effort: (newEffort == nil ? session.effort : newEffort!),
            autopilot: AutopilotState.shared.isEnabled(sessionId: sessionId)
        )
        if newArgv.isEmpty {
            return .spawnError(message: "Could not locate agent binary on PATH")
        }
        registry.updateStatus(id: sessionId, status: .paused)
        AgentEventStream.recordEvent(
            sessionId: sessionId,
            kind: .statusChanged,
            payload: ["status": "paused", "reason": "config-swap"]
        )
        do {
            try await tmux.killPane(oldPaneId)
            let cwd: String
            switch newMode ?? session.mode {
            case .local:    cwd = session.repoKey
            case .worktree: cwd = session.worktreePath ?? session.repoKey
            case .cloud:    cwd = session.repoKey  // not supported v1; fall through
            }
            let newWindowId = try await tmux.newWindow(cwd: cwd, child: newArgv)
            registry.updateRuntime(
                id: sessionId,
                worktreePath: session.worktreePath,
                tmuxWindowId: newWindowId,
                tmuxPaneId: nil,
                mode: newMode ?? session.mode
            )
            if let newModel { registry.setModel(id: sessionId, model: newModel, effort: newEffort ?? session.effort) }
            if let actualEffort = newEffort.flatMap({ $0 }) { registry.setEffort(id: sessionId, effort: actualEffort) }
            if let newPlanMode { registry.setPlanMode(id: sessionId, planMode: newPlanMode) }
            registry.updateStatus(id: sessionId, status: .running)
            AgentEventStream.recordEvent(
                sessionId: sessionId,
                kind: .statusChanged,
                payload: ["status": "running", "reason": "config-swap-complete"]
            )
            return .swapped(newPaneId: newWindowId)
        } catch {
            swapLogger.error("Swap failed for session \(sessionId.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            // D12 resume-fail rescue: try to restore original config in the same window.
            do {
                let restoreWindow = try await tmux.newWindow(cwd: session.worktreePath ?? session.repoKey, child: originalArgv)
                registry.updateRuntime(
                    id: sessionId,
                    worktreePath: session.worktreePath,
                    tmuxWindowId: restoreWindow,
                    tmuxPaneId: nil,
                    mode: session.mode
                )
                registry.updateStatus(id: sessionId, status: .running)
                return .resumeFailed(restoredOriginal: true)
            } catch {
                registry.updateStatus(id: sessionId, status: .degraded)
                return .resumeFailed(restoredOriginal: false)
            }
        }
    }
}

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
        let providerResumeId: String
        if session.agent == .cursor {
            guard let cursorResumeId = Self.cursorResumeId(for: session) else {
                return .spawnError(message: "cursor_resume_id_missing")
            }
            providerResumeId = cursorResumeId
        } else {
            providerResumeId = sessionId.uuidString
        }
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
            // v0.8 schema v5: repoKey is optional. Chat sessions never reach
            // this swap path (they don't expose a Mode chip), so we can fall
            // back to effectiveCwd which crashes loudly if the daemon ever
            // hands us a session without any cwd.
            let cwd: String
            switch newMode ?? session.mode {
            case .local:    cwd = session.repoKey ?? session.effectiveCwd
            case .worktree: cwd = session.effectiveCwd
            case .cloud:    cwd = session.repoKey ?? session.effectiveCwd  // not supported v1; fall through
            }
            let newWindow = try await tmux.newWindow(cwd: cwd, child: newArgv)
            try await registry.updateRuntime(
                id: sessionId,
                worktreePath: session.worktreePath,
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
                let restoreWindow = try await tmux.newWindow(cwd: session.effectiveCwd, child: originalArgv)
                try await registry.updateRuntime(
                    id: sessionId,
                    worktreePath: session.worktreePath,
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

    private static func cursorResumeId(for session: AgentSession) -> String? {
        let candidate = session.runtimeBinding?.externalSessionId
            ?? session.runtimeBinding?.externalThreadId
        guard let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

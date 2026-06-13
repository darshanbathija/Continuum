import Foundation

/// Classifies which sessions can be reconfigured *in place* (model / effort /
/// approval policy) by respawning their managed-harness bridge — the daemon's
/// `reconfigureHarnessCodeSession`. Pure + shared so the routing decision is
/// unit-testable without spinning up the daemon, and so the Mac handlers, the
/// Mac composer chips, and any future iOS-side gate all agree.
public extension AgentKind {
    /// Code sessions on these agents run as a managed harness bridge that takes
    /// its model + approval policy at launch, so a config change is a bridge
    /// kill+respawn: Cursor (ACP), Codex (app-server), Grok + Gemini (headless).
    /// Claude is a direct PTY (handled by `SessionConfigChanger`), OpenCode has
    /// its own SSE path, and `.unknown` is never reconfigurable here. This set
    /// is the exact mirror of the agents `harnessLaunchSpec` knows how to build.
    var isReconfigurableHarness: Bool {
        switch self {
        case .cursor, .codex, .grok, .gemini: return true
        case .claude, .opencode, .unknown: return false
        }
    }
}

public extension AgentSession {
    /// True when this is a *live* managed-harness Code session eligible for an
    /// in-place reconfigure: a reconfigurable-harness agent, a code session, and
    /// no legacy tmux pane metadata (pane-backed sessions are retired and route
    /// to the 410 path instead).
    var isReconfigurableHarnessCodeSession: Bool {
        kind == .code
            && tmuxPaneId == nil
            && tmuxWindowId == nil
            && agent.isReconfigurableHarness
    }
}

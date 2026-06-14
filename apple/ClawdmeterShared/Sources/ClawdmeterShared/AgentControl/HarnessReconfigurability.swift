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

/// How a model pick that crosses provider/vendor families should be carried out
/// on a *live* session. Switching from one vendor's runtime to another's is not
/// a config tweak — it's a runtime kill+respawn, and the new runtime may even be
/// a different *type* (Claude PTY vs managed-harness bridge). Pure + shared so
/// the routing decision is unit-testable without the daemon, and so the Mac
/// in-process path and the daemon endpoint agree on what's supported.
public enum AgentSwitchTarget: Equatable, Sendable {
    /// Same vendor — not a cross-vendor switch; callers use the in-place
    /// same-vendor reconfigure path (`SessionConfigChanger` / harness reconfigure).
    case notCrossVendor
    /// Spawn a fresh Claude PTY (no cross-vendor resume — new conversation).
    case claudePty
    /// Spawn a managed-harness bridge for the new agent (codex/cursor/grok/gemini).
    case harness
    /// Not supported in place yet (OpenCode source/target has no in-place
    /// teardown/respawn analogue; `.unknown` is forward-compat). The reason is
    /// user-facing copy.
    case unsupported(reason: String)
}

/// Classify a cross-vendor live switch from `oldAgent` to `newAgent`. OpenCode
/// (either side) and `.unknown` are deferred with an honest reason rather than a
/// silent chip-only no-op.
public func crossVendorSwitchTarget(from oldAgent: AgentKind, to newAgent: AgentKind) -> AgentSwitchTarget {
    if oldAgent == newAgent { return .notCrossVendor }
    // OpenCode's runtime is an SSE-driven serve process with no in-place
    // teardown/respawn analogue (unlike Claude PTY / managed harness), so a
    // mid-session switch away from it isn't supported yet.
    if oldAgent == .opencode {
        return .unsupported(reason: "Switching away from OpenCode mid-session isn't supported yet — start a new session for the other model.")
    }
    if newAgent == .claude { return .claudePty }
    if newAgent.isReconfigurableHarness { return .harness }
    if newAgent == .opencode {
        return .unsupported(reason: "Switching to OpenCode mid-session isn't supported yet — start a new OpenCode session.")
    }
    return .unsupported(reason: "That agent can't be switched into mid-session.")
}

import Foundation

// SessionCommandRouter — the per-backend command routing the daemon already
// does, named once.
//
// Why this exists: AgentControlServer's write handlers (handleSendPrompt,
// handleInterrupt, handlePermissionRespond) each re-derive "which backend owns
// this session" inline, in a fixed branch order. The branch order is load-
// bearing — e.g. a Codex *SDK chat* must reach the relay before the generic
// tmux paneId guard, and a *live ACP bridge* must win over the legacy tmux
// path even for an old session that predates the harness. Spreading that
// precedence across three handlers makes it easy for a future edit to reorder
// one and not the others. This type captures the precedence in one pure,
// unit-tested place so the handlers can ask instead of re-deriving.
//
// BEHAVIOR-IDENTICAL: this is an extraction, not a change. `resolve` mirrors
// the exact predicate and order of `handleSendPrompt` (the richest of the
// three handlers — it distinguishes every backend). Interrupt and permission-
// respond only distinguish "live ACP bridge vs everything else", so they map
// onto a strict subset of the same precedence (`hasLiveBridge` first, all else
// folds into their existing non-bridge path). See SessionCommandRouterTests.
//
// Lives in ClawdmeterShared (not the Mac target) so it is swift-testable
// without the daemon's Network.framework / tmux dependencies. It references
// only the shared wire enums (AgentKind, SessionRuntimeKind, SessionKind,
// CodexChatBackend, GeminiBackend) — never a Mac-only type. The caller passes
// the live-bridge fact in as a `Bool` because the bridge registry is Mac-only.

/// The backend transport that owns a given command for a session. Each case
/// names the path the daemon dispatches a send/interrupt/permission down.
public enum SessionCommandRoute: String, Hashable, Sendable, CaseIterable {
    /// Antigravity 2 `agentapi` HTTP-RPC (Gemini sessions). Sends go through
    /// `LanguageServerClient.sendMessage`; interrupt is the agentapi `/cancel`
    /// POST (dispatched by SessionInterruptDispatcher today).
    case antigravityAgentapi
    /// Codex SDK chat relay (`CodexSubscriptionRelay`). No tmux pane; sends go
    /// through the SDK ingestor, interrupt is `AbortController.abort()`.
    case codexSDK
    /// OpenCode `opencode serve` HTTP + SSE. Sends POST to
    /// `/session/<id>/message`; the reply streams back over SSE.
    case opencodeServe
    /// Native ACP harness driver (Grok, Cursor) via a *live* `AcpHarnessBridge`.
    /// Sends/interrupts/permissions drive the bridge directly.
    case harnessBridge
    /// The kept Claude / Codex-CLI tmux path. Sends paste into the tmux pane;
    /// interrupt sends ESC via SessionInterruptDispatcher; permissions resolve
    /// the daemon's pending continuation.
    case tmux

    /// True for routes whose live session has no tmux pane. Surfaced for the
    /// caller's diagnostics / parity assertions; the daemon already special-
    /// cases each of these before the tmux paneId guard.
    public var isPaneless: Bool {
        switch self {
        case .antigravityAgentapi, .codexSDK, .opencodeServe, .harnessBridge:
            return true
        case .tmux:
            return false
        }
    }
}

/// Pure resolver for "which backend owns this command". The single source of
/// truth for the precedence that `handleSendPrompt` / `handleInterrupt` /
/// `handlePermissionRespond` currently inline. Stateless — construct once and
/// reuse, or call the static `resolve` directly.
public struct SessionCommandRouter: Sendable {
    public init() {}

    /// The minimal per-session metadata the routing decision needs. Mirrors the
    /// exact fields the daemon's handlers read off `AgentSession` (plus the
    /// Mac-only live-bridge fact, passed as a `Bool`). Optionals match the
    /// AgentSession shape so the daemon can forward them verbatim.
    public struct SessionContext: Sendable {
        public let agent: AgentKind
        public let kind: SessionKind
        public let codexChatBackend: CodexChatBackend?
        public let geminiBackend: GeminiBackend?
        /// `AgentSession.antigravityConversationId != nil`. The agentapi send
        /// path requires a conversation id, so the daemon guards on both
        /// `geminiBackend == .agentapi` AND a non-nil conversation id.
        public let hasAntigravityConversation: Bool
        /// `session.runtimeBinding?.runtimeKind.isACPDriven == true`. Marks a
        /// session that *should* be ACP-driven even when no live bridge exists
        /// (e.g. after a daemon restart killed the in-memory bridge). Used only
        /// for the diagnostic `acpExpectedButNoBridge` flag below — it does NOT
        /// change the resolved route (a paneless ACP session with a dead bridge
        /// still resolves `.tmux`, exactly as the daemon does today, because
        /// the 503-no-live-bridge branch is an error path, not a route).
        public let runtimeIsACPDriven: Bool
        /// `harnessRegistry.bridge(for: id) != nil` on the daemon. A live ACP
        /// bridge wins over the legacy tmux path for the same session.
        public let hasLiveBridge: Bool

        public init(
            agent: AgentKind,
            kind: SessionKind,
            codexChatBackend: CodexChatBackend? = nil,
            geminiBackend: GeminiBackend? = nil,
            hasAntigravityConversation: Bool = false,
            runtimeIsACPDriven: Bool = false,
            hasLiveBridge: Bool = false
        ) {
            self.agent = agent
            self.kind = kind
            self.codexChatBackend = codexChatBackend
            self.geminiBackend = geminiBackend
            self.hasAntigravityConversation = hasAntigravityConversation
            self.runtimeIsACPDriven = runtimeIsACPDriven
            self.hasLiveBridge = hasLiveBridge
        }
    }

    /// Resolve the owning backend for a send-style command. The branch ORDER
    /// below is identical to `handleSendPrompt`'s; do not reorder without
    /// re-checking that handler:
    ///   1. Antigravity agentapi   (geminiBackend == .agentapi && conversation)
    ///   2. Codex SDK chat         (kind == .chat && agent == .codex && backend == .sdk)
    ///   3. OpenCode               (agent == .opencode)
    ///   4. Live ACP bridge        (hasLiveBridge)
    ///   5. tmux                    (fall-through; also where a dead-bridge ACP
    ///                               session lands today before its 503 error
    ///                               path fires — see `acpExpectedButNoBridge`)
    ///
    /// The agentapi branch is FIRST in the daemon "before the chat-tab SDK
    /// dispatch + paneId guard" (AgentControlServer.swift handleSendPrompt) so
    /// a Gemini chat never falls into the Codex-SDK or tmux branches.
    public static func resolve(_ ctx: SessionContext) -> SessionCommandRoute {
        // 1. Antigravity 2 agentapi (Gemini). Requires both the backend axis
        //    and a live conversation id — matches the daemon's
        //    `geminiBackend == .agentapi, let conversationId = ...` guard.
        if ctx.geminiBackend == .agentapi && ctx.hasAntigravityConversation {
            return .antigravityAgentapi
        }
        // 2. Codex SDK chat relay. The three-way conjunction is exactly the
        //    daemon's detection: SDK chat sessions have no tmux pane.
        if ctx.kind == .chat
            && ctx.agent == .codex
            && ctx.codexChatBackend == .sdk {
            return .codexSDK
        }
        // 3. OpenCode. Agent-kind alone — opencode always routes to serve.
        if ctx.agent == .opencode {
            return .opencodeServe
        }
        // 4. Live ACP harness bridge (Grok, Cursor). Keyed off the bridge
        //    registry, agent-agnostic: a session with a live bridge wins over
        //    tmux even if it predates the harness. A dead bridge does NOT match
        //    here (the daemon returns 503 separately) — see the instance method.
        if ctx.hasLiveBridge {
            return .harnessBridge
        }
        // 5. Fall-through: the kept Claude / Codex-CLI tmux path. Back-compat —
        //    an old cursor_cli session with no live bridge lands here, matching
        //    the daemon's behavior before the harness shipped.
        return .tmux
    }

    /// Instance convenience mirroring the static resolver.
    public func route(for ctx: SessionContext) -> SessionCommandRoute {
        Self.resolve(ctx)
    }

    /// Diagnostic: true when the session is *expected* to be ACP-driven
    /// (`runtimeIsACPDriven`) but has no live bridge, so it resolved `.tmux`.
    /// The daemon's handleSendPrompt intercepts exactly this case with an
    /// explicit 503 ("acp_session_not_live") instead of pasting into a
    /// non-existent tmux pane. This is NOT a route — it's the signal the caller
    /// uses to choose the 503 error response over the tmux path. Keeping it
    /// here (rather than re-deriving in the handler) keeps the whole routing
    /// decision in one place and preserves the daemon's exact behavior.
    public static func acpExpectedButNoBridge(_ ctx: SessionContext) -> Bool {
        resolve(ctx) == .tmux && ctx.runtimeIsACPDriven && !ctx.hasLiveBridge
    }
}

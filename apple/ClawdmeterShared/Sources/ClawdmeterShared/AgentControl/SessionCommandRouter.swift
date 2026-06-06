import Foundation

// SessionCommandRouter — the per-backend command routing the daemon already
// does, named once.
//
// Why this exists: AgentControlServer's write handlers (handleSendPrompt,
// handleInterrupt, handlePermissionRespond) each re-derive "which backend owns
// this session" inline, in a fixed branch order. The branch order is load-
// bearing — e.g. a live ACP bridge must win over stale persisted pane metadata
// for an old session that predates the harness. Spreading that
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
// without the daemon's Network.framework / PTY dependencies. It references
// only the shared wire enums (AgentKind, SessionRuntimeKind, SessionKind,
// CodexChatBackend, GeminiBackend) — never a Mac-only type. The caller passes
// the live-bridge fact in as a `Bool` because the bridge registry is Mac-only.

/// The backend transport that owns a given command for a session. Each case
/// names the path the daemon dispatches a send/interrupt/permission down.
public enum SessionCommandRoute: String, Hashable, Sendable, CaseIterable {
    /// OpenCode `opencode serve` HTTP + SSE. Sends POST to
    /// `/session/<id>/message`; the reply streams back over SSE.
    case opencodeServe
    /// Native ACP harness driver (Grok, Cursor) via a *live* `AcpHarnessBridge`.
    /// Sends/interrupts/permissions drive the bridge directly.
    case harnessBridge
    /// A persisted pane/window-backed session from the retired runtime. These
    /// sessions are intentionally not reconnected or migrated; callers surface
    /// a 410 `legacy_session_retired` response.
    case legacyRetired

    /// Per-session direct PTY for Claude (`ClaudePtyHost`). No terminal pane:
    /// sends/interrupts/kills go through `ClaudePtyRegistry`.
    case claudePty

    /// True for routes whose live session has no terminal pane. Surfaced for the
    /// caller's diagnostics / parity assertions; the daemon already special-
    /// cases each of these before the legacy pane metadata guard.
    public var isPaneless: Bool {
        switch self {
        case .opencodeServe, .harnessBridge, .claudePty:
            return true
        case .legacyRetired:
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
        /// `session.runtimeBinding?.runtimeKind.isACPDriven == true`. Marks a
        /// session that *should* be ACP-driven even when no live bridge exists
        /// (e.g. after a daemon restart killed the in-memory bridge). Used only
        /// for the diagnostic `acpExpectedButNoBridge` flag below.
        public let runtimeIsACPDriven: Bool
        /// `harnessRegistry.bridge(for: id) != nil` on the daemon. A live ACP
        /// bridge wins over retired legacy pane metadata for the same session.
        public let hasLiveBridge: Bool
        /// Kept for source compatibility with PR #248 tests/callers. The legacy
        /// fallback flag is retired; Claude now resolves to `.claudePty` when it
        /// has no legacy pane metadata regardless of this value.
        public let claudePtyEnabled: Bool
        /// True when the decoded session still carries old pane/window
        /// metadata. Those persisted fields are compatibility-only now;
        /// pane-bearing sessions resolve `.legacyRetired` and are not
        /// reconnected.
        public let hasLegacyPaneMetadata: Bool

        public init(
            agent: AgentKind,
            kind: SessionKind,
            codexChatBackend: CodexChatBackend? = nil,
            runtimeIsACPDriven: Bool = false,
            hasLiveBridge: Bool = false,
            claudePtyEnabled: Bool = false,
            hasLegacyPaneMetadata: Bool = false
        ) {
            self.agent = agent
            self.kind = kind
            self.codexChatBackend = codexChatBackend
            self.runtimeIsACPDriven = runtimeIsACPDriven
            self.hasLiveBridge = hasLiveBridge
            self.claudePtyEnabled = claudePtyEnabled
            self.hasLegacyPaneMetadata = hasLegacyPaneMetadata
        }
    }

    /// Resolve the owning backend for a send-style command. The branch ORDER
    /// below is identical to `handleSendPrompt`'s; do not reorder without
    /// re-checking that handler:
    ///   1. Live ACP/headless bridge (Grok/Cursor/Codex-app-server/Gemini-agy)
    ///   2. Legacy retired           (old pane/window-backed sessions)
    ///   3. OpenCode                 (`opencode serve`)
    ///   4. Claude PTY               (paneless Claude chat/code)
    ///   5. Legacy retired           (unsupported old paneless sessions)
    public static func resolve(_ ctx: SessionContext) -> SessionCommandRoute {
        // 1. Live ACP harness bridge. Keyed off the bridge registry,
        //    agent-agnostic: a live bridge wins over stale pane metadata.
        if ctx.hasLiveBridge {
            return .harnessBridge
        }
        if isLegacyCodexSDKChat(ctx) {
            return .legacyRetired
        }
        if ctx.hasLegacyPaneMetadata {
            return .legacyRetired
        }
        if ctx.agent == .opencode {
            return .opencodeServe
        }
        if ctx.agent == .claude
            && (ctx.kind == .chat || ctx.kind == .code)
        {
            return .claudePty
        }
        return .legacyRetired
    }

    /// Instance convenience mirroring the static resolver.
    public func route(for ctx: SessionContext) -> SessionCommandRoute {
        Self.resolve(ctx)
    }

    /// Diagnostic: true when the session is *expected* to be ACP-driven
    /// (`runtimeIsACPDriven`) but has no live bridge. The daemon's
    /// handleSendPrompt intercepts exactly this case with an
    /// explicit 503 ("acp_session_not_live") instead of treating the session as
    /// reconnectable. This is NOT a route — it's the signal the caller
    /// uses to choose the 503 error response. Keeping it
    /// here (rather than re-deriving in the handler) keeps the whole routing
    /// decision in one place and preserves the daemon's exact behavior.
    public static func acpExpectedButNoBridge(_ ctx: SessionContext) -> Bool {
        resolve(ctx) == .legacyRetired
            && ctx.runtimeIsACPDriven
            && !ctx.hasLiveBridge
            && !isLegacyCodexSDKChat(ctx)
    }

    private static func isLegacyCodexSDKChat(_ ctx: SessionContext) -> Bool {
        ctx.agent == .codex && ctx.kind == .chat && ctx.codexChatBackend == .sdk
    }
}

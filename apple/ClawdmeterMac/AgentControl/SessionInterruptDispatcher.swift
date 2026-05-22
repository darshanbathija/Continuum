import Foundation
import OSLog
import ClawdmeterShared

private let interruptLogger = Logger(subsystem: "com.clawdmeter.mac", category: "SessionInterrupt")

/// v0.23 (Chat V2): per-backend dispatch for `POST /sessions/:id/interrupt`.
///
/// Pre-V2, `AgentControlServer.handleInterrupt` hard-required a tmux
/// pane id and 404'd otherwise. That's fine for Claude CLI but breaks
/// Stop on Codex SDK chat (Node sidecar — no tmux) and Gemini chat
/// (Antigravity agentapi — no tmux). Codex's outside-voice review
/// (audit P0 #2) flagged this — the V2 composer's Stop button is
/// supposed to work for all three providers. Without this dispatcher,
/// clicking Stop on a non-tmux session would 404 silently and the user
/// would think the UI was broken.
///
/// The dispatcher routes by session backend, NOT by `tmuxPaneId`
/// presence (a session can theoretically be a chat with no pane and
/// still be CLI-mode, e.g. transient spawn failure). Source of truth:
///   - `session.agent == .codex && session.codexChatBackend == .sdk`
///     → SDK sidecar cancel via `CodexSubscriptionRelay`.
///   - `session.agent == .gemini && session.geminiBackend == .agentapi`
///     → Antigravity agentapi via `AntigravityChatIngestor`.
///   - Anything else (Claude tmux, Codex CLI, opencode, unknown)
///     → tmux ESC.
///
/// **Cancel semantics this release**: for SDK + agentapi, "cancel"
/// means tear down the relay / ingestor subscription. The conversation
/// state survives (Codex SDK persists via `codexChatThreadId`;
/// Antigravity persists via `antigravityConversationId` in the SQLite
/// DB), so the next user prompt resumes the same thread. The in-flight
/// response is lost — that's the user-visible behavior of Stop. Per-
/// turn cancel without sidecar respawn lands in v0.23.x once the
/// sidecar's `{op:"stop", subscriptionId}` path is wired through the
/// Swift relay (it already exists in `main.mjs:101`, just unplumbed).
///
/// **Lifecycle transitions emitted on success**: the dispatcher flips
/// the session's `currentTurnState` to `.interrupted` via
/// `SessionChatStore.setCurrentTurnState(.interrupted)` so the V2
/// status strip clamps its stopwatch + restores the Send button.
@MainActor
public final class SessionInterruptDispatcher {

    public enum InterruptResult {
        /// Cancel dispatched successfully. `currentTurnState` is now
        /// `.interrupted` and the V2 UI will update on the next snapshot
        /// commit (~16ms).
        case interrupted
        /// Session id wasn't in the registry. The HTTP handler should
        /// return 404. This is the only "soft" failure — every other
        /// case lands as `.interrupted` because the in-process cancel
        /// dispatches are synchronous void.
        case sessionNotFound
        /// Tmux dispatch failed (sendKeys threw). Caller surfaces
        /// `.internalError` and the daemon logs the underlying error.
        case tmuxFailed
    }

    private weak var registry: AgentSessionRegistry?
    private weak var codexRelay: CodexSubscriptionRelay?
    private weak var tmux: TmuxControlClient?
    private weak var chatStoreRegistry: DaemonChatStoreRegistry?
    /// Resolves the per-session Antigravity ingestor (one per active
    /// agentapi chat). The closure shape lets the daemon hand us a
    /// lookup function without exposing the ingestor pool's full API.
    private let antigravityIngestor: (UUID) -> AntigravityChatIngestor?

    public init(
        registry: AgentSessionRegistry,
        codexRelay: CodexSubscriptionRelay?,
        tmux: TmuxControlClient?,
        chatStoreRegistry: DaemonChatStoreRegistry?,
        antigravityIngestor: @escaping (UUID) -> AntigravityChatIngestor? = { _ in nil }
    ) {
        self.registry = registry
        self.codexRelay = codexRelay
        self.tmux = tmux
        self.chatStoreRegistry = chatStoreRegistry
        self.antigravityIngestor = antigravityIngestor
    }

    /// Dispatch a Stop for `sessionId`. Caller is the HTTP handler;
    /// this method returns the result so the handler can map to a
    /// status code (200 / 404 / 500).
    @discardableResult
    public func interrupt(sessionId: UUID) async -> InterruptResult {
        guard let registry, let session = registry.session(id: sessionId) else {
            interruptLogger.warning("interrupt: session not found \(sessionId.uuidString, privacy: .public)")
            return .sessionNotFound
        }

        // Mark interrupted up front so even if the per-backend dispatch
        // is destructive (full relay teardown), the V2 UI sees the
        // transition immediately and the Send button restores.
        if let store = chatStoreRegistry?.snapshotStore(for: session) {
            store.setCurrentTurnState(.interrupted)
        }

        // Codex SDK: tear down the sidecar; conversation persists via
        // codexChatThreadId so the next send resumes the same thread.
        if session.agent == .codex,
           session.codexChatBackend == .sdk,
           let relay = codexRelay {
            await relay.stop(sessionId: sessionId)
            interruptLogger.info("interrupt: codex-sdk relay stopped session=\(sessionId.uuidString, privacy: .public)")
            return .interrupted
        }

        // Antigravity agentapi: cancel the in-process ingestor; the
        // SQLite-backed conversation state remains in
        // ~/.gemini/antigravity/conversations/<id>.db so the next send
        // resumes against the same conversationId.
        if session.agent == .gemini,
           session.geminiBackend == .agentapi {
            if let ingestor = antigravityIngestor(sessionId) {
                // AntigravityChatIngestor is an `actor` so `stop()`
                // is actor-isolated — must hop.
                await ingestor.stop()
                interruptLogger.info("interrupt: agentapi ingestor stopped session=\(sessionId.uuidString, privacy: .public)")
                return .interrupted
            }
            // No active ingestor — treat as a no-op cancel. The UI's
            // currentTurnState already moved to .interrupted above.
            interruptLogger.info("interrupt: agentapi no active ingestor session=\(sessionId.uuidString, privacy: .public)")
            return .interrupted
        }

        // Default path: tmux ESC. Covers Claude (CLI), Codex CLI,
        // opencode, and any unknown agent that happens to have a pane.
        guard let paneId = session.tmuxPaneId ?? session.tmuxWindowId else {
            // No pane and not a known sidecar-backed session — treat
            // as a soft success because the UI already moved to
            // .interrupted. The actual upstream session may have
            // already completed; we'd return 404 here only if we'd
            // failed to find the session at all (handled above).
            interruptLogger.info("interrupt: no pane id (already done?) session=\(sessionId.uuidString, privacy: .public)")
            return .interrupted
        }
        guard let tmux else {
            interruptLogger.warning("interrupt: tmux client unavailable session=\(sessionId.uuidString, privacy: .public)")
            return .tmuxFailed
        }
        do {
            try await tmux.sendKeys(paneId: paneId, bytes: Data([0x1b])) // ESC
            interruptLogger.info("interrupt: tmux ESC sent session=\(sessionId.uuidString, privacy: .public) pane=\(paneId, privacy: .public)")
            return .interrupted
        } catch {
            interruptLogger.error("interrupt: tmux sendKeys failed session=\(sessionId.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return .tmuxFailed
        }
    }
}

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
///   - Anything else (Claude tmux, Codex CLI, opencode, unknown)
///     → tmux ESC.
///
/// (Harness-driven sessions — agy/gemini, ACP cursor/grok, codex app-server —
/// are interrupted upstream via the bridge in `handleInterrupt` before this
/// dispatcher's tmux fallback is reached.)
///
/// **Cancel semantics**: the dispatcher only returns `.interrupted`
/// after it dispatches a real upstream cancel path (SDK relay stop,
/// agentapi ingestor stop, or tmux ESC). If a backend has no known
/// cancel route, callers get `.notSupported` and must not report
/// success to mobile.
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
        /// No upstream cancel path exists for this session/runtime.
        /// Caller returns 501 `notSupported`.
        case notSupported
    }

    private weak var registry: AgentSessionRegistry?
    private weak var codexRelay: CodexSubscriptionRelay?
    private weak var tmux: TmuxControlClient?
    private weak var chatStoreRegistry: DaemonChatStoreRegistry?

    public init(
        registry: AgentSessionRegistry,
        codexRelay: CodexSubscriptionRelay?,
        tmux: TmuxControlClient?,
        chatStoreRegistry: DaemonChatStoreRegistry?
    ) {
        self.registry = registry
        self.codexRelay = codexRelay
        self.tmux = tmux
        self.chatStoreRegistry = chatStoreRegistry
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

        func markInterrupted() {
            if let store = chatStoreRegistry?.snapshotStore(for: session) {
                store.setCurrentTurnState(.interrupted)
            }
        }

        // Codex SDK: tear down the sidecar; conversation persists via
        // codexChatThreadId so the next send resumes the same thread.
        if session.agent == .codex,
           session.codexChatBackend == .sdk,
           let relay = codexRelay {
            await relay.stop(sessionId: sessionId)
            markInterrupted()
            interruptLogger.info("interrupt: codex-sdk relay stopped session=\(sessionId.uuidString, privacy: .public)")
            return .interrupted
        }

        // Default path: tmux ESC. Covers Claude (CLI), Codex CLI,
        // opencode, and any unknown agent that happens to have a pane.
        guard let paneId = session.tmuxPaneId ?? session.tmuxWindowId else {
            interruptLogger.info("interrupt: no supported cancel path session=\(sessionId.uuidString, privacy: .public)")
            return .notSupported
        }
        guard let tmux else {
            interruptLogger.warning("interrupt: tmux client unavailable session=\(sessionId.uuidString, privacy: .public)")
            return .tmuxFailed
        }
        do {
            try await tmux.sendKeys(paneId: paneId, bytes: Data([0x1b])) // ESC
            markInterrupted()
            interruptLogger.info("interrupt: tmux ESC sent session=\(sessionId.uuidString, privacy: .public) pane=\(paneId, privacy: .public)")
            return .interrupted
        } catch {
            interruptLogger.error("interrupt: tmux sendKeys failed session=\(sessionId.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return .tmuxFailed
        }
    }
}

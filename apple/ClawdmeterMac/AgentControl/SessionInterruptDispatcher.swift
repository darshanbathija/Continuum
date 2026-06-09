import Foundation
import OSLog
import ClawdmeterShared

private let interruptLogger = Logger(subsystem: "com.clawdmeter.mac", category: "SessionInterrupt")

/// v0.23 (Chat V2): per-backend dispatch for `POST /sessions/:id/interrupt`.
///
/// Pre-V2, `AgentControlServer.handleInterrupt` hard-required a pane id and
/// 404'd otherwise. Codex's outside-voice review
/// (audit P0 #2) flagged this — the V2 composer's Stop button is
/// supposed to work for all three providers. Without this dispatcher,
/// clicking Stop on a non-pane session would 404 silently and the user
/// would think the UI was broken.
///
/// The dispatcher handles the fallback after the server's live harness and
/// Claude PTY branches. Anything that reaches this point has no active direct
/// cancel route and is treated as unsupported/retired.
///
/// (Harness-driven sessions — agy/gemini, ACP cursor/grok, codex app-server —
/// are interrupted upstream via the bridge in `handleInterrupt` before this
/// dispatcher is reached.)
///
/// **Cancel semantics**: if a backend has no known cancel route, callers get
/// `.notSupported` and must not report success to mobile.
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
        /// No upstream cancel path exists for this session/runtime.
        /// Caller returns 501 `notSupported`.
        case notSupported
    }

    private weak var registry: AgentSessionRegistry?
    private weak var chatStoreRegistry: DaemonChatStoreRegistry?

    public init(
        registry: AgentSessionRegistry,
        chatStoreRegistry: DaemonChatStoreRegistry?
    ) {
        self.registry = registry
        self.chatStoreRegistry = chatStoreRegistry
    }

    /// Dispatch a Stop for `sessionId`. Caller is the HTTP handler;
    /// this method returns the result so the handler can map to a
    /// status code (200 / 404 / 500).
    @discardableResult
    public func interrupt(sessionId: UUID) async -> InterruptResult {
        guard let registry, registry.session(id: sessionId) != nil else {
            interruptLogger.warning("interrupt: session not found \(sessionId.uuidString, privacy: .public)")
            return .sessionNotFound
        }

        interruptLogger.info("interrupt: no supported cancel path session=\(sessionId.uuidString, privacy: .public)")
        return .notSupported
    }
}

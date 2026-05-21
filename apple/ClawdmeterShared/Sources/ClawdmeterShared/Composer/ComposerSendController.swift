import Foundation
import Combine

/// Composer send-state state machine, shared across every send surface:
/// Mac Code IDE composer, Mac Chat composer, iOS Chat composer, iOS
/// Session Detail composer + plan-halo Refine. Each surface holds its own
/// `@StateObject ComposerSendController` and binds the TextField to
/// `text`, the send button to `send(via:)`, the disabled state to
/// `canSend`, the spinner to `sending`, and any error alert to
/// `lastError`.
///
/// Why this exists (CQ1): before this PR, four surfaces inlined the same
/// ~30-line state machine: trim text → set sending=true → await RPC →
/// clear text on success → populate lastError on failure → reset sending.
/// Single source of truth here.
///
/// Construction takes the `AgentControlClient` the surface uses (Mac
/// loopback or iOS daemon). The controller routes `SendKind` variants
/// to the right client RPC; on any nil/false return, it pulls the
/// client's `lastError` into its own.
@MainActor
public final class ComposerSendController: ObservableObject {

    @Published public var text: String = ""
    @Published public private(set) var sending: Bool = false
    @Published public private(set) var lastError: String?

    private let client: AgentControlClient

    public init(client: AgentControlClient) {
        self.client = client
    }

    public var canSend: Bool {
        guard !sending else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Dispatch the send to the appropriate client RPC. On success the
    /// composer text clears; on failure `lastError` is populated and the
    /// text is preserved so the user can edit and retry.
    public func send(via kind: SendKind) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !sending else { return }
        sending = true
        defer { sending = false }
        lastError = nil

        let preSendClientError = client.lastError

        switch kind {
        case .solo(let sessionId):
            await client.sendPrompt(sessionId: sessionId, text: trimmed, asFollowUp: true)
            if !errorChanged(from: preSendClientError) {
                text = ""
            } else {
                lastError = client.lastError
            }

        case .refine(let sessionId):
            // Refine is semantically identical to a follow-up message
            // (A3: Edit plan = Refine via the same `sendPrompt`).
            await client.sendPrompt(sessionId: sessionId, text: trimmed, asFollowUp: true)
            if !errorChanged(from: preSendClientError) {
                text = ""
            } else {
                lastError = client.lastError
            }

        case .broadcast(let groupId):
            let ok = await client.frontierSend(groupId: groupId, text: trimmed)
            if ok {
                text = ""
            } else {
                lastError = client.lastError ?? "Couldn't fan out to all providers."
            }

        case .chatCreate(let provider, let mode):
            switch mode {
            case .solo:
                let session = await client.createChatSession(provider: provider)
                if let session {
                    // First send: append the prompt to the freshly-created
                    // session. createChatSession spawned the session;
                    // sendPrompt fires the first turn.
                    await client.sendPrompt(sessionId: session.id, text: trimmed, asFollowUp: false)
                    if !errorChanged(from: preSendClientError) {
                        text = ""
                    } else {
                        lastError = client.lastError
                    }
                } else {
                    lastError = client.lastError ?? "Couldn't create chat session."
                }
            case .broadcast:
                // Broadcast frontier creation needs explicit model slots;
                // surface this as a "use createFrontier directly" hint
                // until callers wire the slot list.
                lastError = "Broadcast chat requires explicit model slots — call client.createFrontier(slots:) directly."
            }
        }
    }

    /// Resets composer state. Used when the open session changes (we
    /// don't want a half-typed draft to flow into a different session).
    public func reset() {
        text = ""
        sending = false
        lastError = nil
    }

    private func errorChanged(from baseline: String?) -> Bool {
        client.lastError != baseline && client.lastError != nil
    }
}

/// What kind of send to dispatch. Picked at the call site.
public enum SendKind: Sendable {
    /// Send a follow-up prompt to a specific solo session. Used by the
    /// Code IDE composer + the Chat solo composer.
    case solo(sessionId: UUID)

    /// Plan-halo "Refine" / "Edit plan" — same wire as `.solo` per A3;
    /// kept as a distinct case so callers can apply different UX
    /// (placeholder copy, button label).
    case refine(sessionId: UUID)

    /// Send a message to an existing broadcast (frontier) group; fans
    /// out to all child sessions. PR #25 wires this on both platforms.
    case broadcast(groupId: UUID)

    /// First send with no existing chat session — create it, then send
    /// the user's text as the first turn. Solo creates one session;
    /// Broadcast requires slot list (see controller body).
    case chatCreate(provider: AgentKind, mode: ChatMode)

    public enum ChatMode: Sendable {
        case solo
        case broadcast
    }
}

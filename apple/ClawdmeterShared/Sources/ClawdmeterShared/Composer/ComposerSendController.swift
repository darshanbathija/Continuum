import Foundation
#if canImport(Combine)
import Combine
#endif

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

        // v0.23 (Chat V2 — T10): first-send path that picks up the
        // V2 composer's model + effort + deepResearch state. Mirrors
        // .chatCreate(.solo) but threads the additional fields
        // through createChatSession. Used by MacChatV2View and the
        // upcoming IOSChatV2View when no conversation is open and
        // the user hits Send.
        case .chatCreateV2(let provider, let model, let effort, let deepResearch, let codexBackend):
            let session = await client.createChatSession(
                provider: provider,
                model: model,
                codexBackend: codexBackend,
                effort: effort,
                deepResearch: deepResearch
            )
            if let session {
                await client.sendPrompt(sessionId: session.id, text: trimmed, asFollowUp: false)
                if !errorChanged(from: preSendClientError) {
                    text = ""
                } else {
                    lastError = client.lastError
                }
            } else {
                lastError = client.lastError ?? "Couldn't create chat session."
            }
        }
    }

    /// Dispatch a caller-owned send action while preserving the shared
    /// composer state machine. Used by surfaces whose first-send flow has
    /// to create/select a session or Frontier group before posting text.
    public func sendCustom(action: (String) async -> String?) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !sending else { return }
        sending = true
        defer { sending = false }
        lastError = nil

        if let error = await action(trimmed) {
            lastError = error
        } else {
            text = ""
        }
    }

    /// Like `sendCustom`, but clears the composer text IMMEDIATELY (optimistic)
    /// before running the action, so the message leaves the box without waiting
    /// on session creation / attachment upload / broadcast fan-out. On failure
    /// the text is restored (only if the user hasn't started typing a new draft)
    /// so they can edit and retry.
    public func sendCustomOptimistic(action: @escaping (String) async -> String?) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !sending else { return }
        sending = true
        defer { sending = false }
        lastError = nil
        text = ""   // optimistic: the message is out of the box NOW
        if let error = await action(trimmed) {
            lastError = error
            if text.isEmpty { text = trimmed }   // restore for retry unless user re-typed
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

    /// v0.23 (Chat V2 — T10): V2 first-send case that carries the
    /// composer's full picker state (model, effort, deepResearch,
    /// codexBackend) into the create call. The legacy `.chatCreate`
    /// kept these implicit (CLI default model / no DR / SDK backend);
    /// V2 makes them explicit so the V2 composer pickers actually
    /// affect spawn behavior without going through `sendCustom`.
    case chatCreateV2(
        provider: AgentKind,
        model: String?,
        effort: ReasoningEffort?,
        deepResearch: Bool,
        codexBackend: CodexChatBackend?
    )

    public enum ChatMode: Sendable {
        case solo
        case broadcast
    }
}

import Foundation
import ClawdmeterShared

/// PR #32 chunk 4 — pivots the Mac Chat tab from TahoeDemo to real data.
///
/// Strategy: rather than refactor `ChatStream`'s entire type
/// vocabulary (`ChatThread`, `ChatTurn`, `ChatReply`, `ChatBlock`,
/// `Attached`), this adapter builds a `TahoeDemo.ChatThread`-shaped
/// value from real `[ChatMessage]` data. The existing UI then renders
/// it unchanged. The demo types become a wire format between the data
/// layer and the existing UI — no UI-side refactor required.
///
/// Two construction paths:
///   - **Solo**: 1 session id → a thread populated with that session's
///     provider replies.
///   - **Broadcast**: a frontier group's parent group id + a per-provider
///     `[ChatMessage]` dict → a thread with all 3 (or N) providers'
///     replies on each turn, suitable for the 3-column comparison view.
///
/// The adapter pairs `userText` and the *next* `assistantText` into a
/// turn. Tool calls and meta lines are intentionally collapsed away
/// from the chat view (they live in the per-session Code IDE workspace).
/// Multiple `assistantText` between user prompts get merged into the
/// turn's ChatReply blocks — this matches what a user actually sees in
/// the Claude/Codex TUI for sessions with chain-of-thought-style
/// replies.
@MainActor
public enum MacChatDataAdapter {

    /// Build a single-provider ChatThread from a [ChatMessage] stream.
    /// The thread's title is derived from the session's first user
    /// prompt (capped at 60 chars) so the column header reads
    /// meaningfully.
    public static func soloThread(
        title: String,
        messages: [ChatMessage],
        provider: TahoeProvider,
        modelName: String?
    ) -> TahoeDemo.ChatThread {
        var turns: [TahoeDemo.ChatTurn] = []
        var pendingUser: ChatMessage?
        var pendingAssistantBlocks: [TahoeDemo.ChatBlock] = []

        func flushTurn() {
            guard let user = pendingUser else {
                pendingAssistantBlocks.removeAll()
                return
            }
            let reply = TahoeDemo.ChatReply(
                model: modelName ?? provider.displayName,
                tokens: 0,
                cost: 0,
                time: 0,
                starred: false,
                blocks: pendingAssistantBlocks
            )
            turns.append(TahoeDemo.ChatTurn(
                user: user.body,
                attached: [],
                replies: [provider: reply]
            ))
            pendingUser = nil
            pendingAssistantBlocks.removeAll()
        }

        for message in messages {
            switch message.kind {
            case .userText:
                // A new user prompt closes the previous turn (even if
                // it had no assistant reply yet — appears as a turn
                // with an empty reply column).
                flushTurn()
                pendingUser = message
            case .assistantText:
                // Append paragraph-style blocks; a future polish PR can
                // detect ```code fences in body and emit .code blocks
                // instead. For v1.1.1 we render as plain paragraphs.
                pendingAssistantBlocks.append(.paragraph(message.body))
            case .toolCall, .toolResult, .meta:
                // Collapse — tool noise lives in the Code IDE pane,
                // not the chat hero.
                continue
            }
        }
        // Trailing pending turn.
        flushTurn()

        return TahoeDemo.ChatThread(
            title: deriveTitle(from: title, fallback: turns.first?.user),
            turns: turns
        )
    }

    /// Build a broadcast ChatThread from a per-provider [ChatMessage]
    /// dict. Each provider's stream is paired into turns the same way
    /// `soloThread` does; turns are aligned by user prompt order (the
    /// user's Nth prompt across all 3 children pairs up to produce the
    /// Nth thread turn). Providers whose Nth prompt hasn't landed yet
    /// fall through with an empty reply.
    public static func broadcastThread(
        title: String,
        perProvider: [TahoeProvider: (messages: [ChatMessage], modelName: String?)]
    ) -> TahoeDemo.ChatThread {
        // First decompose each provider's stream into turns.
        var perProviderTurns: [TahoeProvider: [TahoeDemo.ChatTurn]] = [:]
        for (provider, payload) in perProvider {
            let thread = soloThread(
                title: title,
                messages: payload.messages,
                provider: provider,
                modelName: payload.modelName
            )
            perProviderTurns[provider] = thread.turns
        }
        // Then zip-align by user-prompt index. The longest stream
        // dictates the turn count; shorter ones contribute nil replies
        // at the missing indices.
        let maxTurns = perProviderTurns.values.map(\.count).max() ?? 0
        var mergedTurns: [TahoeDemo.ChatTurn] = []
        for i in 0..<maxTurns {
            // Pick a representative user prompt — whichever provider
            // has one at this index gets to anchor the row.
            let userPrompt = perProviderTurns.values
                .compactMap { $0.indices.contains(i) ? $0[i].user : nil }
                .first ?? ""
            var replies: [TahoeProvider: TahoeDemo.ChatReply] = [:]
            for (provider, turns) in perProviderTurns where turns.indices.contains(i) {
                if let reply = turns[i].replies[provider] {
                    replies[provider] = reply
                }
            }
            mergedTurns.append(TahoeDemo.ChatTurn(
                user: userPrompt,
                attached: [],
                replies: replies
            ))
        }
        return TahoeDemo.ChatThread(
            title: deriveTitle(from: title, fallback: mergedTurns.first?.user),
            turns: mergedTurns
        )
    }

    /// AgentKind → TahoeProvider for the broadcast aggregator's key.
    /// Mirrors MacTahoeAdapter.mapAgent but exposed here so callers
    /// outside that file can use it without depending on the adapter
    /// internals.
    public static func tahoeProvider(for agent: AgentKind) -> TahoeProvider {
        switch agent {
        case .claude: return .claude
        case .codex:  return .codex
        case .gemini: return .gemini
        case .opencode: return .opencode
        case .unknown: return .claude  // X3 visual fallback
        }
    }

    /// Pick a short title for the column header. Prefers the session
    /// label (if non-empty); falls back to the first user prompt
    /// truncated.
    private static func deriveTitle(from sessionTitle: String, fallback: String?) -> String {
        let trimmed = sessionTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return String(trimmed.prefix(60)) }
        if let fallback {
            let trimmedFallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedFallback.isEmpty { return String(trimmedFallback.prefix(60)) }
        }
        return "New chat"
    }
}

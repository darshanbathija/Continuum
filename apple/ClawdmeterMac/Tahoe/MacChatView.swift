import SwiftUI
import ClawdmeterShared

/// Mac Chat — the hero tab. Sidebar + 3-column compare (broadcast mode)
/// or single-column Solo mode. Ports `mac-chat.jsx`.
///
/// v0.17 (v1.0 polish): the composer wires through `ComposerSendController`
/// to send real prompts. First send when no chat is open creates a chat
/// session via `client.createChatSession` (solo) or `client.createFrontier`
/// (broadcast). Transcript still renders from `TahoeDemo.chatThread` —
/// the WS-driven transcript store ships in a follow-up; this PR makes
/// the composer alive end-to-end so users can talk to the daemon
/// instead of staring at a decorative placeholder.
public struct MacChatView: View {
    @Environment(\.tahoe) private var t
    public enum Mode: String, CaseIterable, Hashable { case broadcast, solo }

    // JSX puts the MODE toggle INLINE in the titlebar (mac-chat.jsx:175).
    // We lift the state out to MacRootView so the titlebar can host the
    // toggle on the Chat tab; this view receives bindings.
    @Binding var mode: Mode
    @Binding var soloProvider: TahoeProvider

    /// Loopback client. Optional so Previews + the legacy MacRootView
    /// caller can render without one; the runtime always injects.
    private let loopbackClient: AgentControlClient?
    /// PR #32 chunk 4: runtime is used by `MacChatDataAdapter` to
    /// resolve real chat sessions + their `SessionChatStore` for the
    /// transcript pivot. Nil keeps Previews + cold launch on TahoeDemo.
    private weak var runtime: AppRuntime?

    /// Tracks the open chat session id. nil = "no session — first send
    /// creates one". Stored locally; the future MacChatTranscriptStore
    /// hoists this into a shared model.
    @State private var openChatId: UUID?

    /// Internal because `AppRuntime` is internal to the Mac target.
    /// MacChatView is only constructed from MacRootView in this target,
    /// so dropping the public access on the init is safe + correct.
    init(
        mode: Binding<Mode>,
        soloProvider: Binding<TahoeProvider>,
        loopbackClient: AgentControlClient? = nil,
        runtime: AppRuntime? = nil
    ) {
        self._mode = mode
        self._soloProvider = soloProvider
        self.loopbackClient = loopbackClient
        self.runtime = runtime
    }

    /// PR #32 chunk 4: real chat sessions (kind == .chat) the user has
    /// open. Drives the sidebar list. Falls back to demo history when
    /// the loopback client is unavailable (Preview path).
    private var realChatSessions: [AgentSession] {
        loopbackClient?.chatSessions ?? []
    }

    /// Compute the thread to render. Three cases:
    ///   - no openChatId          → empty thread (clean composer state)
    ///   - openChatId, solo mode  → soloThread from chatStore
    ///   - openChatId, broadcast  → broadcastThread aggregating frontier siblings
    ///
    /// v0.22.11: previously the no-openChatId branch returned
    /// `TahoeDemo.chatThread` (the "react-query refactor + tradeoffs"
    /// fixture). That made the Chat tab look like there was an active
    /// conversation when there wasn't — users had to dismiss demo
    /// content before they could start a real chat. Now the default is
    /// a clean empty thread: the composer is the focal point and the
    /// stream pane shows an empty-state hint.
    private var activeThread: TahoeDemo.ChatThread {
        guard let runtime,
              let openId = openChatId,
              let session = runtime.agentSessionRegistry.session(id: openId)
        else {
            return TahoeDemo.ChatThread(title: "", turns: [])
        }
        // Broadcast: the open session is one of N frontier siblings;
        // aggregate all of them into one comparison thread.
        if let groupId = session.frontierGroupId {
            let siblings = runtime.agentSessionRegistry.sessions
                .filter { $0.frontierGroupId == groupId }
            var perProvider: [TahoeProvider: (messages: [ChatMessage], modelName: String?)] = [:]
            for sib in siblings {
                let provider = MacChatDataAdapter.tahoeProvider(for: sib.agent)
                let messages = runtime.agentControlServer.chatStore(for: sib)?.snapshot.messages ?? []
                perProvider[provider] = (messages, sib.model)
            }
            return MacChatDataAdapter.broadcastThread(
                title: session.displayLabel,
                perProvider: perProvider
            )
        }
        // Solo: a single session's transcript.
        let messages = runtime.agentControlServer.chatStore(for: session)?.snapshot.messages ?? []
        return MacChatDataAdapter.soloThread(
            title: session.displayLabel,
            messages: messages,
            provider: MacChatDataAdapter.tahoeProvider(for: session.agent),
            modelName: session.model
        )
    }

    public var body: some View {
        let thread = activeThread
        return HStack(spacing: 10) {
            TahoeGlass(radius: 20, tone: .panel) {
                ChatSidebar(
                    realSessions: realChatSessions,
                    openChatId: $openChatId
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: 248)

            VStack(spacing: 10) {
                ChatColumnHeaders(mode: mode, soloProvider: soloProvider, thread: thread)

                TahoeGlass(radius: 20, tone: .panel) {
                    ChatStream(
                        thread: thread,
                        mode: mode,
                        soloProvider: soloProvider,
                        loopbackClient: loopbackClient,
                        openSession: openChatId.flatMap { runtime?.agentSessionRegistry.session(id: $0) }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxHeight: .infinity)

                ChatComposer(
                    mode: $mode,
                    soloProvider: $soloProvider,
                    loopbackClient: loopbackClient,
                    openChatId: $openChatId
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Mode toggle

/// Mode + Solo provider segmented toggle. Used by `MacRootView` in the
/// titlebar when the Chat tab is active (mac-chat.jsx:175).
struct ChatModeToggle: View {
    @Environment(\.tahoe) private var t
    @Binding var mode: MacChatView.Mode
    @Binding var soloProvider: TahoeProvider

    init(mode: Binding<MacChatView.Mode>, soloProvider: Binding<TahoeProvider>) {
        self._mode = mode
        self._soloProvider = soloProvider
    }

    var body: some View {
        HStack(spacing: 8) {
            Text("MODE")
                .font(TahoeFont.body(11, weight: .bold))
                .tracking(0.4)
                .foregroundStyle(t.fg3)

            segmented([
                (Self.broadcastKey, "Broadcast"),
                (Self.soloKey,      "Solo"),
            ], active: mode == .broadcast ? Self.broadcastKey : Self.soloKey) { k in
                mode = (k == Self.broadcastKey) ? .broadcast : .solo
            }

            if mode == .solo {
                segmentedProvider(active: soloProvider) { soloProvider = $0 }
            }
        }
    }

    private static let broadcastKey = "broadcast"
    private static let soloKey = "solo"

    private func segmented(_ items: [(String, String)], active: String, onSelect: @escaping (String) -> Void) -> some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.0) { (key, label) in
                let isActive = key == active
                Button {
                    onSelect(key)
                } label: {
                    HStack(spacing: 5) {
                        if key == Self.broadcastKey {
                            CompareIconView(size: 10)
                        }
                        Text(label)
                    }
                    .font(TahoeFont.body(11.5, weight: isActive ? .bold : .semibold))
                    .foregroundStyle(isActive ? t.fg : t.fg3)
                    .padding(.horizontal, 11).padding(.vertical, 4)
                    .background {
                        if isActive {
                            Capsule(style: .continuous)
                                .fill(t.dark ? Color(.sRGB, white: 1, opacity: 0.10) : .white)
                                .shadow(color: Color.black.opacity(0.10), radius: 1, x: 0, y: 1)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background {
            Capsule(style: .continuous)
                .fill(t.dark ? Color(.sRGB, white: 1, opacity: 0.06) : Color(.sRGB, white: 15.0/255, opacity: 0.05))
        }
        .overlay {
            Capsule(style: .continuous).stroke(t.hairline, lineWidth: 0.5)
        }
    }

    private func segmentedProvider(active: TahoeProvider, onSelect: @escaping (TahoeProvider) -> Void) -> some View {
        HStack(spacing: 0) {
            ForEach(TahoeProvider.allCases) { p in
                let isActive = p == active
                Button { onSelect(p) } label: {
                    HStack(spacing: 5) {
                        TahoeProviderGlyph(provider: p, size: 14)
                        Text(p.displayName)
                    }
                    .font(TahoeFont.body(11.5, weight: isActive ? .bold : .semibold))
                    .foregroundStyle(isActive ? t.fg : t.fg3)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background {
                        if isActive {
                            Capsule(style: .continuous)
                                .fill(t.dark ? Color(.sRGB, white: 1, opacity: 0.10) : .white)
                                .shadow(color: Color.black.opacity(0.10), radius: 1, x: 0, y: 1)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background {
            Capsule(style: .continuous)
                .fill(t.dark ? Color(.sRGB, white: 1, opacity: 0.06) : Color(.sRGB, white: 15.0/255, opacity: 0.05))
        }
        .overlay {
            Capsule(style: .continuous).stroke(t.hairline, lineWidth: 0.5)
        }
    }
}

/// Custom 3-vertical-bar compare glyph used by the Mode pill — matches the
/// JSX `CompareIcon` in `mac-chat.jsx::CompareIcon` (an SF Symbol equivalent
/// doesn't quite capture the spec, hence the inline Path).
private struct CompareIconView: View {
    var size: CGFloat
    var body: some View {
        Canvas { ctx, _ in
            var path = Path()
            // x=5 y=8..16, x=12 y=4..20, x=19 y=6..18 (24-viewbox)
            let s = size / 24
            for (x, y0, y1) in [(5.0, 8.0, 16.0), (12.0, 4.0, 20.0), (19.0, 6.0, 18.0)] {
                path.move(to: CGPoint(x: x * s, y: y0 * s))
                path.addLine(to: CGPoint(x: x * s, y: y1 * s))
            }
            ctx.stroke(path, with: .foreground, style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Sidebar

private struct ChatSidebar: View {
    @Environment(\.tahoe) private var t
    @State private var openSections: Set<String> = ["Active", "Pinned", "Today", "Earlier"]
    /// PR #32 chunk 4: real chat sessions from the loopback client. Empty
    /// list falls back to the demo history below so the sidebar always
    /// shows something for Previews + cold-launch.
    var realSessions: [AgentSession] = []
    @Binding var openChatId: UUID?

    init(realSessions: [AgentSession] = [], openChatId: Binding<UUID?> = .constant(nil)) {
        self.realSessions = realSessions
        self._openChatId = openChatId
    }

    /// Visible-session de-dupe: broadcast frontier groups appear once
    /// (one entry per group) even though they have N child sessions
    /// internally. The first child whose `frontierChildIndex == 0`
    /// becomes the group's representative; lone solo sessions show as-is.
    private var visibleSessions: [AgentSession] {
        var seenGroups = Set<UUID>()
        var result: [AgentSession] = []
        for session in realSessions {
            if let groupId = session.frontierGroupId {
                if seenGroups.contains(groupId) { continue }
                seenGroups.insert(groupId)
            }
            result.append(session)
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // New chat button
            TahoeAccentButton(size: .m) {
                HStack(spacing: 4) {
                    TahoeIcon("plus", size: 12, weight: .bold)
                    Text("New chat")
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 10)

            // Search field
            HStack(spacing: 8) {
                TahoeIcon("search", size: 12).foregroundStyle(t.fg3)
                Text("Search chats")
                    .font(TahoeFont.body(11.5))
                    .foregroundStyle(t.fg3)
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(t.dark ? Color(.sRGB, white: 1, opacity: 0.06) : Color(.sRGB, white: 15.0/255, opacity: 0.05))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(t.hairline, lineWidth: 0.5)
            }
            .padding(.horizontal, 12).padding(.bottom, 8)

            TahoeHair()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !visibleSessions.isEmpty {
                        // PR #32 chunk 4: live chat sessions from the
                        // daemon. When this section has entries we
                        // hide the legacy demo history entirely —
                        // mixing real + fake rows confused users in
                        // QA.
                        ActiveSessionsSection(
                            label: "Active",
                            sessions: visibleSessions,
                            openChatId: $openChatId,
                            openSections: $openSections
                        )
                    } else {
                        // PR #36 audit-retro: empty-state informational
                        // view replaces the legacy demo history rows
                        // (which had no-op clicks). Honest copy beats
                        // a fake-looking sidebar full of unclickable
                        // rows that the user might mistake for real
                        // sessions.
                        ChatSidebarEmptyState()
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 8)
            }
        }
    }
}

/// PR #32 chunk 4: real-session sidebar section. Renders the live
/// chat sessions (from `client.chatSessions`) as tappable rows that
/// set `openChatId`. Mirrors HistorySection's collapse/expand chrome.
private struct ActiveSessionsSection: View {
    @Environment(\.tahoe) private var t
    var label: String
    var sessions: [AgentSession]
    @Binding var openChatId: UUID?
    @Binding var openSections: Set<String>

    var body: some View {
        let open = openSections.contains(label)
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if open { openSections.remove(label) } else { openSections.insert(label) }
            } label: {
                HStack(spacing: 6) {
                    TahoeIcon(open ? "chevD" : "chevR", size: 9).foregroundStyle(t.fg4)
                    Text(label.uppercased())
                        .font(TahoeFont.body(10, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(t.fg4)
                    Spacer()
                    Text("\(sessions.count)")
                        .font(TahoeFont.mono(10, weight: .semibold))
                        .foregroundStyle(t.fg4)
                }
                .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 4)
            }
            .buttonStyle(.plain)

            if open {
                ForEach(sessions, id: \.id) { session in
                    Button {
                        openChatId = session.id
                    } label: {
                        HStack(spacing: 8) {
                            let provider = MacChatDataAdapter.tahoeProvider(for: session.agent)
                            Circle()
                                .fill(LinearGradient(colors: [provider.glow.color, provider.base.color],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(width: 8, height: 8)
                            Text(session.displayLabel)
                                .font(TahoeFont.body(11.5, weight: openChatId == session.id ? .bold : .medium))
                                .foregroundStyle(openChatId == session.id ? t.fg : t.fg2)
                                .lineLimit(1)
                            Spacer()
                            if session.frontierGroupId != nil {
                                Text("3×")
                                    .font(TahoeFont.mono(9, weight: .bold))
                                    .foregroundStyle(t.accent)
                            }
                        }
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background {
                            if openChatId == session.id {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(t.accent.opacity(0.10))
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                .padding(.bottom, 6)
            }
        }
    }
}

/// PR #36 audit-retro: honest empty-state for the chat sidebar.
/// Replaces the legacy demo HistoryRow placeholders (Pinned / Today /
/// Earlier) that had no-op clicks. The user sees clear copy explaining
/// where chats will appear once they create one.
private struct ChatSidebarEmptyState: View {
    @Environment(\.tahoe) private var t

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TahoeIcon("chat", size: 18).foregroundStyle(t.fg3)
                .padding(.bottom, 2)
            Text("No chats yet")
                .font(TahoeFont.body(12.5, weight: .semibold))
                .foregroundStyle(t.fg2)
            Text("Tap **New chat** above to start a conversation. Active and archived chats will appear here.")
                .font(TahoeFont.body(11))
                .foregroundStyle(t.fg3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 8).padding(.vertical, 14)
    }
}

// PR #36 audit-retro: `HistorySection` + `HistoryRow` retired.
// Both were demo-only: `HistoryRow`'s click was an empty `action: {}`
// and the rows rendered fixture `TahoeDemo.chatHistory` entries that
// didn't correspond to any real chat session. Replaced by the
// `ChatSidebarEmptyState` informational view above (when no real
// sessions exist) and `ActiveSessionsSection` (when they do).

// MARK: - Column headers

private struct ChatColumnHeaders: View {
    var mode: MacChatView.Mode
    var soloProvider: TahoeProvider
    var thread: TahoeDemo.ChatThread

    var providers: [TahoeProvider] {
        mode == .solo ? [soloProvider] : [.claude, .codex, .gemini]
    }

    var body: some View {
        HStack(spacing: 10) {
            ForEach(providers) { p in
                ColumnHeader(provider: p, stats: totals(for: p))
                    .frame(maxWidth: .infinity)
            }
        }
    }

    struct Stats { var tok: Int; var cost: Double; var wins: Int; var lastTime: Double; var model: String }

    private func totals(for p: TahoeProvider) -> Stats {
        let replies = thread.turns.compactMap { $0.replies[p] }
        let tok = replies.reduce(0) { $0 + $1.tokens }
        let cost = replies.reduce(0) { $0 + $1.cost }
        let wins = replies.filter { $0.starred }.count
        let lastTime = replies.last?.time ?? 0
        return Stats(tok: tok, cost: cost, wins: wins, lastTime: lastTime, model: replies.first?.model ?? "")
    }
}

private struct ColumnHeader: View {
    @Environment(\.tahoe) private var t
    var provider: TahoeProvider
    var stats: ChatColumnHeaders.Stats

    var body: some View {
        TahoeGlass(radius: 14, tone: .raised) {
            VStack(spacing: 0) {
                // Brand rule on top
                LinearGradient(colors: [provider.glow.color, provider.base.color],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(height: 2)
                    .shadow(color: provider.base.color(opacity: 0.55), radius: 6, x: 0, y: 0)

                HStack(spacing: 10) {
                    TahoeProviderGlyph(provider: provider, size: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(provider.displayName)
                            .font(TahoeFont.body(13, weight: .bold))
                            .tracking(-0.1)
                            .foregroundStyle(t.fg)
                        Text(stats.model)
                            .font(TahoeFont.mono(10.5))
                            .foregroundStyle(t.fg3)
                    }
                    Spacer(minLength: 4)
                    Stat(label: "tok",  value: tahoeFmtTok(stats.tok))
                    Stat(label: "cost", value: String(format: "$%.3f", stats.cost))
                    Stat(label: "last", value: String(format: "%.1fs", stats.lastTime))
                    Stat(label: "wins", value: "\(stats.wins)", highlight: true)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
        }
    }
}

private struct Stat: View {
    @Environment(\.tahoe) private var t
    var label: String
    var value: String
    var highlight: Bool = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(value)
                .font(TahoeFont.mono(13, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(highlight ? t.accent : t.fg)
            Text(label.uppercased())
                .font(TahoeFont.body(9, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(t.fg4)
        }
        .frame(minWidth: 38, alignment: .trailing)
    }
}

// MARK: - Stream

private struct ChatStream: View {
    @Environment(\.tahoe) private var t
    var thread: TahoeDemo.ChatThread
    var mode: MacChatView.Mode
    var soloProvider: TahoeProvider
    /// PR #32 chunk 4: loopback client + open session — needed for the
    /// frontier pick-winner button on broadcast turns. Optional so the
    /// existing previews (no real backend) keep rendering.
    var loopbackClient: AgentControlClient? = nil
    var openSession: AgentSession? = nil

    var providers: [TahoeProvider] {
        mode == .solo ? [soloProvider] : [.claude, .codex, .gemini]
    }

    /// Frontier group id for the currently-open session, when in
    /// broadcast mode. nil → pick-winner button is hidden (solo session
    /// or no session open).
    private var openFrontierGroupId: UUID? {
        openSession?.frontierGroupId
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 8) {
                    Text(thread.title.uppercased())
                        .font(TahoeFont.body(11, weight: .bold))
                        .tracking(0.5)
                        .foregroundStyle(t.fg3)
                    TahoeHair(vertical: true).frame(height: 10)
                    Text("\(thread.turns.count) turn\(thread.turns.count == 1 ? "" : "s") · " +
                         (mode == .broadcast ? "broadcasting to 3 models" : "solo — \(soloProvider.displayName)"))
                        .font(TahoeFont.mono(11, weight: .semibold))
                        .foregroundStyle(t.fg4)
                    Spacer()
                    if let groupId = openFrontierGroupId, mode == .broadcast {
                        // PR #32 chunk 4: pick-winner button — visible
                        // only when an open broadcast session has a
                        // frontier group. Tap fans out a request to
                        // frontierPickWinner(groupId:childIndex:),
                        // archiving the losers + leaving the winner as
                        // the surviving solo session.
                        PickWinnerMenu(
                            groupId: groupId,
                            providers: providers,
                            loopbackClient: loopbackClient
                        )
                    }
                }
                ForEach(Array(thread.turns.enumerated()), id: \.offset) { idx, turn in
                    Turn(turn: turn, providers: providers, index: idx)
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 16)
        }
    }
}

private struct Turn: View {
    var turn: TahoeDemo.ChatTurn
    var providers: [TahoeProvider]
    var index: Int

    var body: some View {
        VStack(spacing: 10) {
            UserMessage(text: turn.user, attached: turn.attached, index: index)
            HStack(alignment: .top, spacing: 10) {
                ForEach(providers) { p in
                    if let reply = turn.replies[p] {
                        AssistantCard(provider: p, reply: reply, solo: providers.count == 1)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }
}

private struct UserMessage: View {
    @Environment(\.tahoe) private var t
    var text: String
    var attached: [TahoeDemo.Attached]
    var index: Int

    var body: some View {
        TahoeGlass(radius: 14, tone: .chip) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(t.dark ? Color(.sRGB, white: 1, opacity: 0.10) : Color(.sRGB, white: 15.0/255, opacity: 0.08))
                    Text("\(index + 1)")
                        .font(TahoeFont.mono(11, weight: .bold))
                        .foregroundStyle(t.fg2)
                }
                .frame(width: 26, height: 26)

                VStack(alignment: .leading, spacing: 4) {
                    Text("YOU")
                        .font(TahoeFont.body(10.5, weight: .bold))
                        .tracking(0.4)
                        .foregroundStyle(t.fg3)
                    Text(text)
                        .font(TahoeFont.body(13.5))
                        .foregroundStyle(t.fg)
                        .fixedSize(horizontal: false, vertical: true)
                    if !attached.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(attached, id: \.name) { a in
                                HStack(spacing: 5) {
                                    TahoeIcon("doc", size: 10)
                                    Text(a.name)
                                    Text(a.range).foregroundStyle(t.fg4).padding(.leading, 4)
                                }
                                .font(TahoeFont.mono(11))
                                .foregroundStyle(t.fg2)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background {
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(t.dark ? Color(.sRGB, white: 1, opacity: 0.06) : Color(.sRGB, white: 15.0/255, opacity: 0.05))
                                }
                                .overlay {
                                    RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(t.hairline, lineWidth: 0.5)
                                }
                            }
                        }
                        .padding(.top, 8)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
    }
}

private struct AssistantCard: View {
    @Environment(\.tahoe) private var t
    var provider: TahoeProvider
    var reply: TahoeDemo.ChatReply
    var solo: Bool

    var body: some View {
        TahoeGlass(radius: 14, tone: .raised) {
            VStack(alignment: .leading, spacing: 0) {
                LinearGradient(colors: [provider.glow.color, provider.base.color],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(height: 2)
                    .opacity(0.85)
                HStack(spacing: 8) {
                    TahoeProviderGlyph(provider: provider, size: 20)
                    Text(provider.displayName)
                        .font(TahoeFont.body(12, weight: .bold))
                        .foregroundStyle(t.fg)
                    Text(reply.model)
                        .font(TahoeFont.mono(10.5))
                        .foregroundStyle(t.fg4)
                    Spacer()
                    // D7 (audit retro): drop StarButton — never wired,
                    // never asked for. Pick-winner lives in the
                    // ChatStream header for broadcast turns.
                }
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)
                TahoeHair()
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(reply.blocks.enumerated()), id: \.offset) { _, b in
                        switch b {
                        case .paragraph(let text):
                            Text(text)
                                .font(TahoeFont.body(solo ? 13.5 : 12.5))
                                .foregroundStyle(t.fg)
                                .fixedSize(horizontal: false, vertical: true)
                        case .code(let lang, let code):
                            CodeBlock(code: code, lang: lang)
                        }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                TahoeHair()
                HStack(spacing: 10) {
                    ReplyMeta(icon: "sparkles", value: tahoeFmtTok(reply.tokens), suffix: "tok")
                    ReplyMeta(icon: nil, value: String(format: "$%.3f", reply.cost), suffix: nil)
                    ReplyMeta(icon: nil, value: String(format: "%.1fs", reply.time), suffix: nil)
                    Spacer()
                    // D7 (audit retro): drop refresh + arrowR (share)
                    // icons that were never wired. Keep Copy (doc icon)
                    // — wired to NSPasteboard with the reply body.
                    CopyReplyButton(reply: reply)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
        }
    }
}

private struct CodeBlock: View {
    @Environment(\.tahoe) private var t
    var code: String
    var lang: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(lang.uppercased())
                .font(TahoeFont.body(9.5, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(t.fg4)
            ScrollView(.horizontal) {
                Text(code)
                    .font(TahoeFont.mono(11))
                    .foregroundStyle(t.fg)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(t.dark ? Color.black.opacity(0.30) : Color(.sRGB, white: 15.0/255, opacity: 0.04))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(t.hairline, lineWidth: 0.5)
        }
    }
}

private struct ReplyMeta: View {
    @Environment(\.tahoe) private var t
    var icon: String?
    var value: String
    var suffix: String?
    var body: some View {
        HStack(spacing: 4) {
            if let icon { TahoeIcon(icon, size: 10) }
            Text(value).foregroundStyle(t.fg2).fontWeight(.semibold)
            if let suffix { Text(suffix).foregroundStyle(t.fg4) }
        }
        .font(TahoeFont.mono(11))
        .foregroundStyle(t.fg3)
    }
}

/// PR #34: D7-compliant copy button for the Mac chat reply card.
/// Mirrors `IOSReplyAction(icon: "doc", action: copy)` on iOS — joins
/// every block's text into one pasteboard string.
private struct CopyReplyButton: View {
    @Environment(\.tahoe) private var t
    var reply: TahoeDemo.ChatReply

    var body: some View {
        Button(action: copy) {
            TahoeIcon("doc", size: 12)
                .foregroundStyle(t.fg3)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .help("Copy reply text")
    }

    private func copy() {
        let combined = reply.blocks.map { block -> String in
            switch block {
            case .paragraph(let s): return s
            case .code(_, let body): return body
            }
        }.joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(combined, forType: .string)
    }
}

// MARK: - Pick winner (PR #32 chunk 4)

/// Per-provider winner picker for broadcast frontier groups. Each
/// item in the menu calls `client.frontierPickWinner(groupId:childIndex:)`
/// — the daemon archives the losers + leaves the winner as the
/// surviving solo session that subsequent prompts route to.
private struct PickWinnerMenu: View {
    @Environment(\.tahoe) private var t
    var groupId: UUID
    var providers: [TahoeProvider]
    var loopbackClient: AgentControlClient?

    @State private var isPicking: Bool = false

    var body: some View {
        Menu {
            ForEach(Array(providers.enumerated()), id: \.offset) { index, provider in
                Button {
                    pickWinner(index: index)
                } label: {
                    Label("Keep \(provider.displayName)", systemImage: "checkmark.seal")
                }
            }
        } label: {
            HStack(spacing: 4) {
                if isPicking {
                    ProgressView().controlSize(.mini)
                } else {
                    TahoeIcon("checkmark.seal", size: 11).foregroundStyle(t.accent)
                }
                Text("Pick winner")
                    .font(TahoeFont.body(11, weight: .semibold))
                    .foregroundStyle(t.accent)
                TahoeIcon("chevD", size: 8).foregroundStyle(t.accent.opacity(0.7))
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background {
                Capsule().fill(t.accent.opacity(0.12))
            }
            .overlay {
                Capsule().stroke(t.accent.opacity(0.35), lineWidth: 0.5)
            }
        }
        .buttonStyle(.plain)
        .disabled(isPicking || loopbackClient == nil)
    }

    private func pickWinner(index: Int) {
        guard let client = loopbackClient else { return }
        isPicking = true
        Task { @MainActor in
            _ = await client.frontierPickWinner(groupId: groupId, childIndex: index)
            isPicking = false
        }
    }
}

// MARK: - Composer

private struct ChatComposer: View {
    @Environment(\.tahoe) private var t
    @Binding var mode: MacChatView.Mode
    @Binding var soloProvider: TahoeProvider
    /// Daemon client for create / send. Nil = decorative (Preview).
    var loopbackClient: AgentControlClient?
    /// Tracks the open chat session id at the parent. nil means "no
    /// open session — first send creates one then writes here".
    @Binding var openChatId: UUID?

    /// v0.17: the composer owns its own state machine. ComposerSendController
    /// trims input, tracks `sending`, and surfaces `lastError`. The button
    /// + TextField bind through it so a misclick can't double-fire and the
    /// UI disables itself while the daemon roundtrips.
    @StateObject private var sendCtl: ComposerSendController
    @FocusState private var textFocused: Bool
    /// Soft warning surfaced when broadcast mode falls back to a Solo
    /// chat (broadcast fan-out lands in the follow-up PR). The view
    /// renders this above lastError so the user knows the prompt
    /// still reached Claude even if it didn't fan out to 3 providers.
    @State private var broadcastNote: String?

    init(
        mode: Binding<MacChatView.Mode>,
        soloProvider: Binding<TahoeProvider>,
        loopbackClient: AgentControlClient?,
        openChatId: Binding<UUID?>
    ) {
        self._mode = mode
        self._soloProvider = soloProvider
        self.loopbackClient = loopbackClient
        self._openChatId = openChatId
        // Mirror the IOSChatView pattern: fall back to a UserDefaults-
        // backed client when not yet wired (Previews + unconfigured
        // launches). The `sendNow` guard `loopbackClient != nil` blocks
        // real RPCs while the fallback client still satisfies the
        // controller's `init(client:)` contract.
        let client = loopbackClient ?? AgentControlClient()
        _sendCtl = StateObject(wrappedValue: ComposerSendController(client: client))
    }

    var body: some View {
        TahoeGlass(radius: 18, tone: .raised) {
            VStack(alignment: .leading, spacing: 0) {
                // Real TextField. axis: .vertical lets the field grow up
                // to ~6 lines before scrolling, matching the JSX behavior.
                // disableAutocorrection because the user is typing
                // prompts, not prose — autocorrect inverts CamelCase
                // identifiers and file names.
                TextField(placeholder, text: $sendCtl.text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .font(TahoeFont.body(14))
                    .foregroundStyle(t.fg)
                    .autocorrectionDisabled()
                    .focused($textFocused)
                    .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 4)
                    .onSubmit { sendNow() }
                    .disabled(sendCtl.sending)

                if let note = broadcastNote {
                    Text(note)
                        .font(TahoeFont.body(11))
                        .foregroundStyle(t.fg3)
                        .padding(.horizontal, 16).padding(.bottom, 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let error = sendCtl.lastError {
                    Text(error)
                        .font(TahoeFont.body(11))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 16).padding(.bottom, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 6) {
                    // v0.22.9: multi-select model picker replaces the
                    // titlebar "MODE [Broadcast] [Solo]" toggle. Click
                    // the chip → toggle providers; 1 = solo, >1 = broadcast.
                    BroadcastChip(mode: $mode, soloProvider: $soloProvider)
                    TahoeComposerChip(icon: "paperclip", action: { Self.attachFile(into: $sendCtl.text) })
                    TahoeComposerChip(icon: "code", action: { Self.insertCodeBlock(into: $sendCtl.text) })
                    TahoeComposerChip(icon: "mic", action: { Self.openDictation() })
                    Menu {
                        Text("Autopilot")
                            .foregroundStyle(.secondary)
                        Divider()
                        Text("Plan-mode toggle is a Code tab feature")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } label: {
                        TahoeComposerChip(icon: "bolt", label: "auto", caret: true)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    Spacer()
                    Text(costEstimate)
                        .font(TahoeFont.mono(11))
                        .foregroundStyle(t.fg4)
                        .padding(.trailing, 4)
                    SendButton(
                        enabled: sendCtl.canSend && loopbackClient != nil,
                        sending: sendCtl.sending,
                        action: sendNow
                    )
                }
                .padding(.horizontal, 12).padding(.bottom, 12).padding(.top, 4)
            }
        }
        .onAppear { textFocused = true }
    }

    private var placeholder: String {
        if mode == .broadcast {
            return "Ask all three. Use / for skills, @ for files. Press ⏎ to send to Claude · Codex · Antigravity."
        }
        return "Ask \(soloProvider.displayName). Use / for skills, @ for files."
    }

    // MARK: - v0.22.9: composer chip helpers (mirrors MacCodeView)

    /// Open NSOpenPanel and append `@/absolute/path` mentions to the
    /// composer text. Multi-select. The agent's prompt parser handles
    /// the `@path` token convention.
    fileprivate static func attachFile(into composerText: Binding<String>) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canResolveUbiquitousConflicts = true
        panel.title = "Attach files"
        panel.prompt = "Attach"
        if panel.runModal() == .OK {
            let mentions = panel.urls
                .map { "@\($0.path)" }
                .joined(separator: " ")
            if composerText.wrappedValue.isEmpty {
                composerText.wrappedValue = "\(mentions) "
            } else if composerText.wrappedValue.hasSuffix(" ") {
                composerText.wrappedValue += "\(mentions) "
            } else {
                composerText.wrappedValue += " \(mentions) "
            }
        }
    }

    fileprivate static func insertCodeBlock(into composerText: Binding<String>) {
        let stub = composerText.wrappedValue.isEmpty
            ? "```\n\n```\n"
            : "\n\n```\n\n```\n"
        composerText.wrappedValue += stub
    }

    fileprivate static func openDictation() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.keyboard?Dictation") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Cost estimate label — PR #31 chunk 4 wired to Pricing.estimateSend.
    /// Returns a live estimate based on the current draft text + the
    /// picked agent's default model. Broadcast sums all 3 providers'
    /// default models; solo shows just the picked one.
    private var costEstimate: String {
        let text = sendCtl.text
        // Pick default models for the estimator. These match the same
        // catalog defaults the spawn path picks up via
        // ComposerStore.ChipDefaults — keeps the chip in lockstep with
        // what'll actually run.
        let agent = currentAgentKind
        let defaultModel = ComposerStore.ChipDefaults.for(agent: agent).modelId ?? ""
        let estimate: Decimal
        if mode == .broadcast {
            let trio: [(AgentKind, String)] = [
                (.claude, ComposerStore.ChipDefaults.for(agent: .claude).modelId ?? ""),
                (.codex,  ComposerStore.ChipDefaults.for(agent: .codex).modelId ?? ""),
                (.gemini, ComposerStore.ChipDefaults.for(agent: .gemini).modelId ?? ""),
            ].filter { !$0.1.isEmpty }
            estimate = Pricing.shared.estimateBroadcast(promptText: text, agentModels: trio)
        } else {
            estimate = Pricing.shared.estimateSend(
                promptText: text, agent: agent, model: defaultModel
            )
        }
        return Self.formatCost(estimate) + " / send"
    }

    /// Currency formatter for the composer chip. Uses 3 decimal places
    /// because per-send estimates are typically under $0.10 — 2 decimals
    /// would show "$0.01" for everything between $0.005 and $0.015.
    private static func formatCost(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.maximumFractionDigits = 3
        formatter.minimumFractionDigits = 3
        return formatter.string(from: value as NSDecimalNumber) ?? "$0.000"
    }

    /// Wire-up entry point: either send to the open chat or create a
    /// new one and route the prompt as the first message. Mirrors
    /// `IOSChatView`'s send loop so behavior across surfaces is uniform.
    /// The ComposerSendController already binds to the loopback client
    /// at init, so it handles both the create + first-send transition
    /// (.chatCreate) and the follow-up send (.solo) cases.
    private func sendNow() {
        guard loopbackClient != nil, sendCtl.canSend else { return }
        // The controller owns the create + send transition via
        // `.chatCreate`, which spawns a session and routes the prompt
        // as the first turn. For broadcast we'd want `.broadcast` —
        // but that wire requires explicit frontier slots, which lands
        // in the follow-up. For v1.0 polish we route broadcast through
        // .chatCreate(solo) so the prompt still reaches the daemon and
        // surface a soft warning that fan-out is queued.
        let pendingProvider = currentAgentKind
        let pendingMode = mode
        Task { @MainActor in
            broadcastNote = nil
            if let openId = openChatId {
                // Existing session — straight send-as-followup. If the
                // open session is part of a frontier group, route via
                // frontierSend to fan out to all siblings instead.
                if let groupId = loopbackClient?.sessions
                    .first(where: { $0.id == openId })?.frontierGroupId {
                    let trimmed = sendCtl.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let client = loopbackClient, !trimmed.isEmpty else { return }
                    _ = await client.frontierSend(groupId: groupId, text: trimmed)
                    sendCtl.text = ""
                } else {
                    await sendCtl.send(via: .solo(sessionId: openId))
                }
                return
            }
            // First send. Two paths:
            //  - solo: use the controller's .chatCreate which spawns
            //    one chat session and posts the prompt as turn-1.
            //  - broadcast: spawn a Frontier group via createFrontier
            //    with claude/codex/gemini slots, then route the prompt
            //    via frontierSend. The opencode case is opt-in (a
            //    follow-up adds an "include opencode" toggle to the
            //    chip).
            if pendingMode == .broadcast {
                guard let client = loopbackClient else { return }
                let trimmed = sendCtl.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                let slots: [FrontierModelSlot] = [
                    FrontierModelSlot(provider: .claude),
                    FrontierModelSlot(provider: .codex),
                    FrontierModelSlot(provider: .gemini),
                ]
                let response = await client.createFrontier(slots: slots)
                guard let response else {
                    broadcastNote = "Couldn't create broadcast group — see Settings → Providers."
                    return
                }
                _ = await client.frontierSend(groupId: response.groupId, text: trimmed)
                sendCtl.text = ""
                // Pick whichever child landed first as the openChatId
                // so the UI focuses on this new group; the data adapter
                // resolves siblings via the frontierGroupId on the
                // session record.
                let firstChild = (loopbackClient?.chatSessions ?? [])
                    .first(where: { $0.frontierGroupId == response.groupId })
                openChatId = firstChild?.id
                return
            }
            // Solo path.
            let beforeIds = Set((loopbackClient?.chatSessions ?? []).map(\.id))
            await sendCtl.send(via: .chatCreate(provider: pendingProvider, mode: .solo))
            let after = loopbackClient?.chatSessions ?? []
            if let newSession = after.first(where: { !beforeIds.contains($0.id) }) {
                openChatId = newSession.id
            }
        }
    }

    private var currentAgentKind: AgentKind {
        switch soloProvider {
        case .claude: return .claude
        case .codex:  return .codex
        case .gemini: return .gemini
        case .opencode: return .opencode  // PR #31
        }
    }
}

/// Local lightweight enum for the in-composer mode hint. Mirrors the
/// ComposerSendController.SendKind.ChatMode shape; declared inline so
/// the composer doesn't need to pull in SendKind for what amounts to a
/// branch tag.
private enum ChatMode { case solo, broadcast }

/// v0.22.9: was `BroadcastChip` (static label). Now a Menu-bound chip
/// that lets the user multi-select which providers receive the prompt.
/// Replaces the titlebar "MODE [Broadcast] [Solo]" toggle entirely —
/// selection count drives mode automatically:
///   - 1 selected → solo mode, that provider
///   - >1 selected → broadcast mode
/// Selecting zero providers re-checks the last one (we always have at
/// least one recipient).
private struct BroadcastChip: View {
    @Environment(\.tahoe) private var t
    @Binding var mode: MacChatView.Mode
    @Binding var soloProvider: TahoeProvider

    /// Currently-selected providers. Derived from `mode` + `soloProvider`
    /// so the menu opens reflecting the live state and persisting back
    /// re-maps the set into mode/soloProvider.
    private var selectedSet: Set<TahoeProvider> {
        switch mode {
        case .broadcast: return [.claude, .codex, .gemini]
        case .solo:      return [soloProvider]
        }
    }

    private var displayProviders: [TahoeProvider] {
        TahoeProvider.allCases.filter { selectedSet.contains($0) }
    }

    private var label: String {
        let count = selectedSet.count
        if count == 1, let only = selectedSet.first {
            return only.displayName
        }
        return "\(count) models"
    }

    var body: some View {
        Menu {
            ForEach([TahoeProvider.claude, .codex, .gemini], id: \.self) { p in
                let on = selectedSet.contains(p)
                Button {
                    toggle(p)
                } label: {
                    Label(p.displayName, systemImage: on ? "checkmark.circle.fill" : "circle")
                }
            }
        } label: {
            chipLabel
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    @ViewBuilder
    private var chipLabel: some View {
        HStack(spacing: 6) {
            HStack(spacing: -5) {
                ForEach(displayProviders) { p in
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(LinearGradient(colors: [p.glow.color, p.base.color],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 14, height: 14)
                        .overlay {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .stroke(t.dark ? Color(.sRGB, red: 13.0/255, green: 14.0/255, blue: 17.0/255) : Color.white, lineWidth: 1.5)
                        }
                }
            }
            Text(label)
                .font(TahoeFont.body(11.5, weight: .semibold))
            TahoeIcon("chevD", size: 9).opacity(0.7)
        }
        .foregroundStyle(t.accent)
        .padding(.horizontal, 8).padding(.vertical, 0)
        .frame(height: 26)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(t.accentAlpha(t.dark ? 0.16 : 0.10))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(t.accentAlpha(0.45), lineWidth: 0.5)
        }
    }

    /// Toggle a provider in the selection. Maps the resulting set back
    /// to `mode` + `soloProvider`. Refuses to drop the last selection
    /// (the composer needs at least one recipient).
    private func toggle(_ p: TahoeProvider) {
        var next = selectedSet
        if next.contains(p) {
            if next.count <= 1 { return }   // refuse to clear the last one
            next.remove(p)
        } else {
            next.insert(p)
        }
        if next.count == 1, let only = next.first {
            mode = .solo
            soloProvider = only
        } else {
            mode = .broadcast
        }
    }
}

private struct SendButton: View {
    @Environment(\.tahoe) private var t
    var enabled: Bool
    var sending: Bool
    var action: () -> Void

    init(enabled: Bool = true, sending: Bool = false, action: @escaping () -> Void = {}) {
        self.enabled = enabled
        self.sending = sending
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(LinearGradient(colors: [t.accent, t.accentDeepC],
                                             startPoint: .top, endPoint: .bottom))
                if sending {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    TahoeIcon("arrowU", size: 15, weight: .bold)
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 34, height: 34)
            .opacity(enabled ? 1.0 : 0.5)
            .shadow(color: t.accentDeep.color(opacity: 0.30), radius: 6, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

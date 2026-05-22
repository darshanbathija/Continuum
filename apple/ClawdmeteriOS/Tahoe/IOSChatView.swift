import SwiftUI
import ClawdmeterShared

/// iOS Chat tab — broadcast strip + per-turn model pills + active reply card.
/// Ports `ios-chat.jsx`.
///
/// Wiring pass: composer sends render real chat snapshots.
/// Broadcast uses Frontier create/send; solo uses chat-create/send. Demo
/// transcript is reserved for Previews/unpaired state only.
public struct IOSChatView: View {
    @Environment(\.tahoe) private var t
    @State private var activeByTurn: [Int: TahoeProvider] = [:]
    @State private var broadcast: Bool = true
    @State private var openChatId: UUID?
    @State private var openFrontierGroupId: UUID?
    @State private var providersResponse: ChatProvidersResponse?
    /// v0.22.5 chat-UX fixes: persist the user's picked send-agent so
    /// the composer chip + first-send route through it. Stored locally
    /// (per-launch); future polish promotes to UserDefaults.
    @State private var pickedAgent: AgentKind = .claude
    /// v0.22.5: drives the chat-history sheet that the "archive" /
    /// "+" header buttons present. Lists `agentClient.chatSessions`
    /// so the user can actually find their past chats.
    @State private var historySheetPresented: Bool = false
    @ObservedObject private var client: AgentControlClient
    private let injectedClient: Bool
    @StateObject private var composerController: ComposerSendController

    public init(agentClient: AgentControlClient? = nil) {
        let client = agentClient ?? AgentControlClient()
        self._client = ObservedObject(wrappedValue: client)
        self.injectedClient = agentClient != nil
        _composerController = StateObject(wrappedValue: ComposerSendController(client: client))
    }

    public var body: some View {
        VStack(spacing: 0) {
            IOSLargeTitle(title: "Chat", subtitle: "Clawdmeter") {
                HStack(spacing: 10) {
                    // v0.22.5: "archive" header icon → opens the chat
                    // history sheet (lists all chat sessions). Was a
                    // decorative no-op icon. The same sheet doubles
                    // as the "all chats" view the user couldn't reach.
                    IOSRoundIconBtn("archive", action: {
                        historySheetPresented = true
                    })
                    // v0.22.5: "+" header icon → start a fresh chat by
                    // resetting the composer (clears the open thread).
                    // First-send then creates a new session via the
                    // ComposerSendController's .chatCreate path.
                    IOSRoundIconBtn("plus", action: {
                        openChatId = nil
                        openFrontierGroupId = nil
                        composerController.reset()
                    })
                }
            }

            // Broadcast strip
            TahoeGlass(radius: 14, tone: .chip) {
                HStack(spacing: 10) {
                    HStack(spacing: -6) {
                        ForEach(availableFrontierProviders) { p in
                            TahoeProviderGlyph(provider: p, size: 22)
                        }
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Broadcast to all three")
                            .font(TahoeFont.body(12.5, weight: .bold))
                            .foregroundStyle(t.fg)
                        Text("Compare answers · tap a model to read its reply")
                            .font(TahoeFont.body(10.5))
                            .foregroundStyle(t.fg3)
                    }
                    Spacer()
                    TahoeToggleView(on: $broadcast)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !injectedClient {
                        Text("\(TahoeDemo.chatThread.title.uppercased()) · \(TahoeDemo.chatThread.turns.count) TURNS")
                            .font(TahoeFont.body(10.5, weight: .bold))
                            .tracking(0.5)
                            .foregroundStyle(t.fg4)
                            .padding(.horizontal, 4).padding(.top, 2).padding(.bottom, 10)
                        ForEach(Array(TahoeDemo.chatThread.turns.enumerated()), id: \.offset) { idx, turn in
                            IOSTurnRow(
                                turn: turn, index: idx,
                                activeProvider: Binding(
                                    get: { activeByTurn[idx] ?? defaultStarred(turn) ?? .claude },
                                    set: { activeByTurn[idx] = $0 }
                                )
                            )
                            .padding(.bottom, 18)
                        }
                    } else if let groupId = openFrontierGroupId {
                        IOSFrontierThread(
                            groupId: groupId,
                            client: client,
                            activeSessionId: $openChatId
                        )
                    } else if let openChatId {
                        IOSChatSnapshotThread(
                            sessionId: openChatId,
                            client: client,
                            provider: tahoeProvider(for: openSession?.agent ?? pickedAgent)
                        )
                        .id(openChatId)
                    } else {
                        emptyState
                    }
                    Spacer().frame(height: 12)
                }
                .padding(.horizontal, 16).padding(.top, 12)
            }
            .frame(maxHeight: .infinity)
            // v0.22.5: drag-down to dismiss the keyboard while
            // scrolling — was missing entirely, so users had no way
            // to put away the keyboard without tapping outside the
            // textfield (and nothing outside was tappable).
            .scrollDismissesKeyboard(.interactively)

            // Floating composer above the tab bar — JSX positions this at
            // bottom: 92 inside the iPhone frame; in our SwiftUI shell we
            // put it after the scroll view so it stays glued to the bottom
            // of the content area, just above the floating tab bar.
            IOSChatComposer(
                controller: composerController,
                broadcastMode: broadcast,
                isReachable: injectedClient,
                pickedAgent: $pickedAgent,
                availableAgents: availableSoloAgents,
                onSend: { text in
                    await sendChat(text)
                }
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
        }
        // v0.22.5: chat history sheet — lists real client.chatSessions
        // so the user can find/resume past chats. The "archive" + "+"
        // header buttons present this; tapping a row should select it.
        .sheet(isPresented: $historySheetPresented) {
            IOSChatHistorySheet(
                sessions: client.chatSessions,
                onSelect: { session in
                    openChatId = session.id
                    openFrontierGroupId = session.frontierGroupId
                    pickedAgent = supportedAgent(session.agent) ?? pickedAgent
                    historySheetPresented = false
                },
                onDismiss: { historySheetPresented = false }
            )
        }
        .task {
            await client.refreshSessions()
            providersResponse = await client.fetchChatProviders()
            normalizePickedAgent()
        }
    }

    private func defaultStarred(_ turn: TahoeDemo.ChatTurn) -> TahoeProvider? {
        turn.replies.first { _, r in r.starred }?.key
    }

    private var openSession: AgentSession? {
        guard let openChatId else { return nil }
        return client.sessions.first { $0.id == openChatId }
    }

    private var usableProviderKinds: [AgentKind] {
        guard let providers = providersResponse?.providers else {
            return [.claude, .codex, .gemini]
        }
        let usable = providers.compactMap { entry -> AgentKind? in
            guard entry.available, entry.authenticated, entry.capabilityProbePassed else { return nil }
            return supportedAgent(entry.provider)
        }
        var seen: Set<AgentKind> = []
        return usable.filter { seen.insert($0).inserted }
    }

    private var availableSoloAgents: [AgentKind] {
        usableProviderKinds
    }

    private var availableFrontierAgents: [AgentKind] {
        availableSoloAgents.filter { $0 == .claude || $0 == .codex || $0 == .gemini }
    }

    private var availableFrontierProviders: [TahoeProvider] {
        let providers = availableFrontierAgents.map(tahoeProvider(for:))
        return providers.isEmpty && providersResponse == nil ? [.claude, .codex, .gemini] : providers
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 8) {
            TahoeIcon("chat", size: 24).foregroundStyle(t.fg4)
            Text("New chat")
                .font(TahoeFont.body(14, weight: .semibold))
                .foregroundStyle(t.fg2)
            Text("Send a message to start a solo chat, or keep broadcast on to fan out through Frontier.")
                .font(TahoeFont.body(12))
                .foregroundStyle(t.fg3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 300)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }

    @MainActor
    private func sendChat(_ text: String) async -> String? {
        if let groupId = openFrontierGroupId {
            return await client.frontierSend(groupId: groupId, text: text)
                ? nil
                : (client.lastError ?? "Couldn't send to broadcast group.")
        }
        if let openChatId {
            return await client.sendPrompt(sessionId: openChatId, text: text, asFollowUp: true)
                ? nil
                : (client.lastError ?? "Couldn't send to chat.")
        }
        if broadcast {
            let slots = availableFrontierAgents.map { FrontierModelSlot(provider: $0) }
            guard !slots.isEmpty else { return "No supported broadcast providers are available." }
            guard let response = await client.createFrontier(slots: slots) else {
                return client.lastError ?? "Couldn't create broadcast group."
            }
            let liveSlots = response.slots.filter { $0.sessionId != nil }
            guard !liveSlots.isEmpty else {
                let reasons = response.slots.compactMap(\.reason).joined(separator: ", ")
                return "All providers failed to spawn\(reasons.isEmpty ? "." : ": \(reasons)")"
            }
            guard await client.frontierSend(groupId: response.groupId, text: text) else {
                return client.lastError ?? "Couldn't send to broadcast group."
            }
            openFrontierGroupId = response.groupId
            openChatId = client.frontierChildren(groupId: response.groupId).first?.id ?? liveSlots.first?.sessionId
            return nil
        }
        guard let agent = supportedAgent(pickedAgent) ?? availableSoloAgents.first else {
            return "No supported chat provider is available."
        }
        guard let session = await client.createChatSession(provider: agent) else {
            return client.lastError ?? "Couldn't create chat session."
        }
        guard await client.sendPrompt(sessionId: session.id, text: text, asFollowUp: false) else {
            return client.lastError ?? "Couldn't send to chat."
        }
        openChatId = session.id
        openFrontierGroupId = nil
        return nil
    }

    private func normalizePickedAgent() {
        if !availableSoloAgents.contains(pickedAgent), let first = availableSoloAgents.first {
            pickedAgent = first
        }
    }

    private func supportedAgent(_ kind: AgentKind) -> AgentKind? {
        switch kind {
        case .claude, .codex, .gemini: return kind
        case .opencode, .unknown: return nil
        }
    }

    private func tahoeProvider(for kind: AgentKind) -> TahoeProvider {
        switch kind {
        case .claude: return .claude
        case .codex: return .codex
        case .gemini: return .gemini
        case .opencode: return .opencode
        case .unknown: return .claude
        }
    }
}

private struct IOSFrontierThread: View {
    @Environment(\.tahoe) private var t
    let groupId: UUID
    @ObservedObject var client: AgentControlClient
    @Binding var activeSessionId: UUID?

    private var children: [AgentSession] {
        client.frontierChildren(groupId: groupId)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                ForEach(children) { child in
                    Button {
                        activeSessionId = child.id
                    } label: {
                        HStack(spacing: 5) {
                            TahoeProviderGlyph(provider: provider(for: child.agent), size: 18)
                            Text(provider(for: child.agent).displayName)
                                .font(TahoeFont.body(10.5, weight: activeSessionId == child.id ? .bold : .semibold))
                                .lineLimit(1)
                        }
                        .foregroundStyle(activeSessionId == child.id ? t.fg : t.fg3)
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(activeSessionId == child.id ? t.accentAlpha(0.14) : Color.clear)
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(activeSessionId == child.id ? t.accentAlpha(0.4) : t.hairline, lineWidth: 0.5)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            if let active = activeSessionId ?? children.first?.id {
                IOSChatSnapshotThread(
                    sessionId: active,
                    client: client,
                    provider: provider(for: children.first(where: { $0.id == active })?.agent ?? .claude)
                )
                .id(active)
            } else {
                Text("Waiting for broadcast sessions…")
                    .font(TahoeFont.body(12))
                    .foregroundStyle(t.fg3)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 60)
            }
        }
    }

    private func provider(for kind: AgentKind) -> TahoeProvider {
        switch kind {
        case .claude: return .claude
        case .codex: return .codex
        case .gemini: return .gemini
        case .opencode: return .opencode
        case .unknown: return .claude
        }
    }
}

private struct IOSChatSnapshotThread: View {
    @Environment(\.tahoe) private var t
    let sessionId: UUID
    let provider: TahoeProvider
    @StateObject private var store: iOSChatStore

    init(sessionId: UUID, client: AgentControlClient, provider: TahoeProvider) {
        self.sessionId = sessionId
        self.provider = provider
        _store = StateObject(wrappedValue: iOSChatStore(sessionId: sessionId, client: client))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if store.snapshot.items.isEmpty {
                Text("Waiting for the first reply…")
                    .font(TahoeFont.body(12))
                    .foregroundStyle(t.fg3)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 60)
            } else {
                ForEach(store.snapshot.items) { item in
                    IOSChatWireItemRow(item: item, provider: provider)
                }
            }
        }
        .task(id: sessionId) {
            await store.refresh()
            store.start()
        }
        .onDisappear {
            store.stop()
        }
    }
}

private struct IOSChatWireItemRow: View {
    @Environment(\.tahoe) private var t
    var item: ChatItem
    var provider: TahoeProvider

    var body: some View {
        switch item {
        case .message(let message):
            messageRow(message)
        case .toolRun(_, let pairs):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(pairs) { pair in
                    compactToolRow(pair.call)
                    if let result = pair.result {
                        compactToolRow(result)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func messageRow(_ message: ChatMessage) -> some View {
        switch message.kind {
        case .userText:
            HStack {
                Spacer()
                VStack(alignment: .leading, spacing: 6) {
                    Text(message.body)
                        .font(TahoeFont.body(14))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background {
                    UnevenRoundedRectangle(
                        topLeadingRadius: 18, bottomLeadingRadius: 18,
                        bottomTrailingRadius: 18, topTrailingRadius: 6
                    )
                    .fill(LinearGradient(colors: [t.accent, t.accentDeepC],
                                         startPoint: .top, endPoint: .bottom))
                }
                .frame(maxWidth: 320, alignment: .trailing)
            }
        case .assistantText:
            HStack(alignment: .top, spacing: 9) {
                TahoeProviderGlyph(provider: provider, size: 24)
                Text(message.body)
                    .font(TahoeFont.body(14))
                    .foregroundStyle(t.fg)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
        case .toolCall, .toolResult:
            compactToolRow(message)
        case .meta:
            Text(message.body)
                .font(TahoeFont.body(11.5))
                .foregroundStyle(t.fg3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func compactToolRow(_ message: ChatMessage) -> some View {
        HStack(spacing: 8) {
            TahoeIcon(message.kind == .toolCall ? "doc" : "check", size: 11).foregroundStyle(t.fg3)
            Text(message.title)
                .font(TahoeFont.body(11.5, weight: .semibold))
                .foregroundStyle(t.fg2)
            Text(message.body)
                .font(TahoeFont.mono(11))
                .foregroundStyle(message.isError ? .red : t.fg3)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 4).padding(.vertical, 4)
    }
}

// MARK: - Turn

private struct IOSTurnRow: View {
    @Environment(\.tahoe) private var t
    var turn: TahoeDemo.ChatTurn
    var index: Int
    @Binding var activeProvider: TahoeProvider

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            IOSUserBubble(text: turn.user, attached: turn.attached, index: index)
            HStack(spacing: 6) {
                ForEach(TahoeProvider.allCases) { p in
                    if let reply = turn.replies[p] {
                        ModelPill(provider: p, reply: reply, active: p == activeProvider) {
                            activeProvider = p
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(.top, 10).padding(.bottom, 8)

            if let reply = turn.replies[activeProvider] {
                IOSReplyCard(provider: activeProvider, reply: reply)
            }
        }
    }
}

private struct IOSUserBubble: View {
    @Environment(\.tahoe) private var t
    var text: String
    var attached: [TahoeDemo.Attached]
    var index: Int

    var body: some View {
        HStack {
            Spacer()
            VStack(alignment: .leading, spacing: 8) {
                Text(text)
                    .font(TahoeFont.body(14))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                if !attached.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(attached, id: \.name) { a in
                            HStack(spacing: 4) {
                                TahoeIcon("doc", size: 10).foregroundStyle(.white)
                                Text(a.name).foregroundStyle(.white)
                                Text(a.range).foregroundStyle(Color.white.opacity(0.7))
                            }
                            .font(TahoeFont.mono(11))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.white.opacity(0.16))
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background {
                UnevenRoundedRectangle(
                    topLeadingRadius: 18, bottomLeadingRadius: 18,
                    bottomTrailingRadius: 18, topTrailingRadius: 6
                )
                .fill(LinearGradient(colors: [t.accent, t.accentDeepC],
                                     startPoint: .top, endPoint: .bottom))
            }
            .shadow(color: t.accentDeep.color(opacity: 0.30), radius: 7, x: 0, y: 4)
            .frame(maxWidth: .infinity * 0.88, alignment: .trailing)
        }
    }
}

private struct ModelPill: View {
    @Environment(\.tahoe) private var t
    var provider: TahoeProvider
    var reply: TahoeDemo.ChatReply
    var active: Bool
    var onSelect: () -> Void

    private var tintMul: Double { provider == .codex ? 2.4 : 1.0 }

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    TahoeProviderGlyph(provider: provider, size: 22)
                    if reply.starred {
                        ZStack {
                            Circle().fill(t.accent)
                            // JSX renders a 7-unit star in 24-viewBox at 13px →
                            // ~4pt. v1 had this at 6pt, visibly oversized.
                            Image(systemName: "star.fill")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        .frame(width: 13, height: 13)
                        .overlay { Circle().stroke(t.dark ? Color(.sRGB, red: 13.0/255, green: 14.0/255, blue: 17.0/255) : .white, lineWidth: 1.5) }
                        .offset(x: 6, y: -6)
                    }
                }
                Text(provider.displayName)
                    .font(TahoeFont.body(10.5, weight: active ? .bold : .semibold))
                    .foregroundStyle(active ? t.fg : t.fg2)
                    .lineLimit(1)
                Text("\(String(format: "%.1f", reply.time))s · \(tahoeFmtTok(reply.tokens))")
                    .font(TahoeFont.mono(9.5))
                    .monospacedDigit()
                    .foregroundStyle(t.fg4)
            }
            .padding(.horizontal, 6).padding(.top, 8).padding(.bottom, 6)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(active
                          ? provider.base.color(opacity: (t.dark ? 0.32 : 0.18) * tintMul)
                          : (t.dark ? Color(.sRGB, white: 1, opacity: 0.04) : Color(.sRGB, white: 15.0/255, opacity: 0.03)))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(active ? provider.base.color(opacity: 0.55) : t.hairline, lineWidth: active ? 1 : 0.5)
            }
            .shadow(color: active ? provider.base.color(opacity: 0.25) : .clear, radius: 6, x: 0, y: 4)
        }
        .buttonStyle(.plain)
    }
}

private struct IOSReplyCard: View {
    @Environment(\.tahoe) private var t
    var provider: TahoeProvider
    var reply: TahoeDemo.ChatReply

    var body: some View {
        TahoeGlass(radius: 18, tone: .raised) {
            VStack(alignment: .leading, spacing: 0) {
                LinearGradient(colors: [provider.glow.color, provider.base.color],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(height: 2)
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(reply.blocks.enumerated()), id: \.offset) { _, b in
                        switch b {
                        case .paragraph(let text):
                            Text(text)
                                .font(TahoeFont.body(13.5))
                                .lineSpacing(13.5 * 0.55) // matches JSX `lineHeight: 1.55`
                                .foregroundStyle(t.fg)
                                .fixedSize(horizontal: false, vertical: true)
                        case .code(_, let code):
                            ScrollView(.horizontal) {
                                Text(code)
                                    .font(TahoeFont.mono(11))
                                    .foregroundStyle(t.fg)
                                    // JSX `padding: '10px 12px'` (ios-chat.jsx:308)
                                    .padding(.vertical, 10).padding(.horizontal, 12)
                            }
                            .background {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(t.dark ? Color.black.opacity(0.32) : Color(.sRGB, white: 15.0/255, opacity: 0.04))
                            }
                            .overlay {
                                RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(t.hairline, lineWidth: 0.5)
                            }
                        }
                    }
                }
                // JSX `padding: '14px 16px 10px'` (ios-chat.jsx:268) — asymmetric.
                .padding(.top, 14).padding(.horizontal, 16).padding(.bottom, 10)

                TahoeHair()

                HStack(spacing: 8) {
                    Text("\(tahoeFmtTok(reply.tokens)) tok · $\(String(format: "%.3f", reply.cost)) · \(String(format: "%.1f", reply.time))s")
                        .font(TahoeFont.mono(10.5))
                        .foregroundStyle(t.fg3)
                    Spacer()
                    // D7: refresh + star icons retired. Copy stays.
                    IOSReplyAction(icon: "doc", action: {
                        let combined = reply.blocks.map { block -> String in
                            switch block {
                            case .paragraph(let s): return s
                            case .code(_, let body): return body
                            }
                        }.joined(separator: "\n\n")
                        UIPasteboard.general.string = combined
                    })
                    // PR #36 audit-retro: PickWinnerButton was always
                    // decorative — iOS chat doesn't construct frontier
                    // sessions yet (single-column UI). Removed from the
                    // reply card here; comes back as part of the v1.2
                    // iOS broadcast UI (with real groupId + childIndex
                    // threaded through) when that surface is built.
                    // See `docs/button-wiring-audit.md` for the v1.2
                    // scope description.
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
        }
    }
}

private struct IOSReplyAction: View {
    @Environment(\.tahoe) private var t
    var icon: String
    var action: () -> Void = {}
    var body: some View {
        Button(action: action) {
            TahoeIcon(icon, size: 12)
                .foregroundStyle(t.fg2)
                .frame(width: 28, height: 28)
                .background {
                    Circle().fill(t.dark ? Color(.sRGB, white: 1, opacity: 0.06) : Color(.sRGB, white: 15.0/255, opacity: 0.04))
                }
        }
        .buttonStyle(.plain)
    }
}

// PR #36 audit-retro: `PickWinnerButton` removed. It was always
// decorative (empty action handler) — iOS chat doesn't construct
// frontier (broadcast) sessions yet, so there was no groupId or
// childIndex to fire against. The button comes back as part of the
// v1.2 iOS broadcast UI surface with proper wiring threaded through.

// MARK: - Composer

private struct IOSChatComposer: View {
    @Environment(\.tahoe) private var t
    @ObservedObject var controller: ComposerSendController
    var broadcastMode: Bool
    var isReachable: Bool
    /// v0.22.5: which agent the first-send routes to. Wired to a
    /// real `Menu` chip so the user can switch between supported chat
    /// providers without leaving the chat.
    @Binding var pickedAgent: AgentKind
    var availableAgents: [AgentKind]
    var onSend: (String) async -> String?

    private var placeholder: String {
        if !isReachable { return "Pair to Mac to start a chat…" }
        if broadcastMode { return "Ask all three…" }
        return "Ask \(displayName(for: pickedAgent))…"
    }

    var body: some View {
        TahoeGlass(radius: 26, tone: .raised) {
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    // v0.22.5: agent picker Menu replaces the dead
                    // "+" attach icon (file/image attach is a v1.x
                    // backend feature — was never wired). Tap to
                    // switch which provider gets the first turn.
                    agentPickerMenu
                    TextField(placeholder, text: $controller.text, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(TahoeFont.body(14))
                        .foregroundStyle(t.fg)
                        .lineLimit(1...4)
                        .disabled(!isReachable || controller.sending)
                        .submitLabel(.send)
                        .onSubmit { Task { await sendNow() } }
                    Spacer(minLength: 4)
                    // Dictation removed (was decorative icon, not a real
                    // mic button — system keyboard already exposes
                    // dictation via the globe key).
                    Button(action: { Task { await sendNow() } }) {
                        ZStack {
                            Circle().fill(LinearGradient(colors: [t.accent, t.accentDeepC],
                                                         startPoint: .top, endPoint: .bottom))
                            if controller.sending {
                                ProgressView().controlSize(.small).tint(.white)
                            } else {
                                TahoeIcon("arrowU", size: 14, weight: .bold).foregroundStyle(.white)
                            }
                        }
                        .frame(width: 32, height: 32)
                        .shadow(color: t.accentDeep.color(opacity: 0.30), radius: 6, x: 0, y: 4)
                        .opacity(controller.canSend && isReachable ? 1.0 : 0.45)
                    }
                    .buttonStyle(.plain)
                    .disabled(!controller.canSend || !isReachable)
                }
            }
            .padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity)
    }

    /// v0.22.5: SwiftUI Menu wrapping the agent picker. Replaces the
    /// previously-decorative `TahoeIcon("plus")` attach icon. Tap
    /// opens a native iOS popup with the supported provider options.
    @ViewBuilder
    private var agentPickerMenu: some View {
        Menu {
            ForEach(availableAgents, id: \.self) { kind in
                Button {
                    pickedAgent = kind
                } label: {
                    HStack {
                        Text(displayName(for: kind))
                        if pickedAgent == kind {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                TahoeIcon(iconName(for: pickedAgent), size: 14)
                    .foregroundStyle(t.accent)
                TahoeIcon("chevD", size: 8).foregroundStyle(t.fg3)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background {
                Capsule().fill(t.accentAlpha(0.12))
            }
            .overlay {
                Capsule().stroke(t.accentAlpha(0.35), lineWidth: 0.5)
            }
        }
        .disabled(!isReachable || controller.sending)
        .help("Pick which model handles the next message")
    }

    private func displayName(for kind: AgentKind) -> String {
        switch kind {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .gemini: return "Antigravity"
        case .opencode: return "OpenCode"
        case .unknown: return "Other"
        }
    }

    private func iconName(for kind: AgentKind) -> String {
        switch kind {
        case .claude: return "sparkles"
        case .codex, .gemini, .opencode, .unknown: return "sparkles"
        }
    }

    private func sendNow() async {
        guard isReachable else { return }
        await controller.sendCustom(action: onSend)
    }
}

// MARK: - Chat history sheet (v0.22.5)

/// iOS chat history surface — presented from the "archive" + "+"
/// header buttons in `IOSChatView`. Lists every `AgentSession`
/// where `kind == .chat`, sorted by most-recent first. The previous
/// build had no view for "show me all my chats" — users could only
/// see whichever single thread the demo data rendered.
///
/// Tapping a row opens that real chat in the main view.
private struct IOSChatHistorySheet: View {
    @Environment(\.tahoe) private var t
    var sessions: [AgentSession]
    var onSelect: (AgentSession) -> Void
    var onDismiss: () -> Void

    private var sortedChatSessions: [AgentSession] {
        sessions
            .filter { $0.kind == .chat && $0.archivedAt == nil }
            .sorted { $0.lastEventAt > $1.lastEventAt }
    }

    var body: some View {
        NavigationStack {
            Group {
                if sortedChatSessions.isEmpty {
                    VStack(spacing: 10) {
                        TahoeIcon("chat", size: 24).foregroundStyle(t.fg4)
                        Text("No chats yet")
                            .font(TahoeFont.body(14, weight: .semibold))
                            .foregroundStyle(t.fg2)
                        Text("New chats appear here once you send your first message.")
                            .font(TahoeFont.body(12))
                            .foregroundStyle(t.fg3)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 280)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(sortedChatSessions, id: \.id) { session in
                        Button(action: { onSelect(session) }) {
                            HStack(spacing: 12) {
                                TahoeProviderGlyph(
                                    provider: tahoeProvider(for: session.agent),
                                    size: 24
                                )
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(session.displayLabel)
                                        .font(TahoeFont.body(14, weight: .semibold))
                                        .foregroundStyle(t.fg)
                                        .lineLimit(1)
                                    Text(session.model ?? "—")
                                        .font(TahoeFont.body(11))
                                        .foregroundStyle(t.fg3)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Chats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: onDismiss)
                }
            }
        }
    }

    private func tahoeProvider(for agent: AgentKind) -> TahoeProvider {
        switch agent {
        case .claude: return .claude
        case .codex: return .codex
        case .gemini: return .gemini
        case .opencode: return .opencode
        case .unknown: return .claude
        }
    }
}

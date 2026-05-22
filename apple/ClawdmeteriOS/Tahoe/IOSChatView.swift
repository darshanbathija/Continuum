import SwiftUI
import ClawdmeterShared

/// iOS Chat tab — broadcast strip + per-turn model pills + active reply card.
/// Ports `ios-chat.jsx`.
///
/// v0.15 (PR #25, D1 partial): composer wired through
/// `ComposerSendController` — first send creates a chat session via
/// `client.createChatSession` and dispatches the user's text as the
/// first turn. Reply-card Copy button uses UIPasteboard. Refresh /
/// share / star icons retired per D7. The full broadcast streaming UI
/// (WS subscription + per-provider columns) lands in a v1.x follow-up;
/// today's TahoeDemo.chatThread fixture still drives the visual.
public struct IOSChatView: View {
    @Environment(\.tahoe) private var t
    @State private var activeByTurn: [Int: TahoeProvider] = [:]
    @State private var broadcast: Bool = true
    /// v0.22.5 chat-UX fixes: persist the user's picked send-agent so
    /// the composer chip + first-send route through it. Stored locally
    /// (per-launch); future polish promotes to UserDefaults.
    @State private var pickedAgent: AgentKind = .claude
    /// v0.22.5: drives the chat-history sheet that the "archive" /
    /// "+" header buttons present. Lists `agentClient.chatSessions`
    /// so the user can actually find their past chats.
    @State private var historySheetPresented: Bool = false
    /// Optional agent client passed down by IOSRootView when paired.
    /// Nil in Previews / unpaired — composer disables itself.
    var agentClient: AgentControlClient?
    @StateObject private var composerController: ComposerSendController

    public init(agentClient: AgentControlClient? = nil) {
        self.agentClient = agentClient
        let client = agentClient ?? AgentControlClient()
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
                        composerController.reset()
                    })
                }
            }

            // Broadcast strip
            TahoeGlass(radius: 14, tone: .chip) {
                HStack(spacing: 10) {
                    HStack(spacing: -6) {
                        ForEach(TahoeProvider.allCases) { p in
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
                isReachable: agentClient != nil,
                pickedAgent: $pickedAgent
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
        }
        // v0.22.5: chat history sheet — lists real client.chatSessions
        // so the user can find/resume past chats. The "archive" + "+"
        // header buttons present this; tapping a row should select it.
        .sheet(isPresented: $historySheetPresented) {
            IOSChatHistorySheet(
                sessions: agentClient?.chatSessions ?? [],
                onDismiss: { historySheetPresented = false }
            )
        }
    }

    private func defaultStarred(_ turn: TahoeDemo.ChatTurn) -> TahoeProvider? {
        turn.replies.first { _, r in r.starred }?.key
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
    /// real `Menu` chip so the user can switch between
    /// Claude / Codex / Gemini / OpenCode without leaving the chat.
    @Binding var pickedAgent: AgentKind

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
    /// opens a native iOS popup with the 4 provider options.
    @ViewBuilder
    private var agentPickerMenu: some View {
        Menu {
            ForEach(AgentKind.allCases, id: \.self) { kind in
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
        // v0.22.5: route the first send through the user-picked agent
        // (was hardcoded to .claude before). AgentKind value comes from
        // the in-composer Menu chip's binding.
        await controller.send(via: .chatCreate(provider: pickedAgent, mode: .solo))
    }
}

// MARK: - Chat history sheet (v0.22.5)

/// iOS chat history surface — presented from the "archive" + "+"
/// header buttons in `IOSChatView`. Lists every `AgentSession`
/// where `kind == .chat`, sorted by most-recent first. The previous
/// build had no view for "show me all my chats" — users could only
/// see whichever single thread the demo data rendered.
///
/// v0.22.5 cut: shows the list + a Done button. Tapping a row
/// dismisses (deep-link to "open this chat in the main view" needs
/// the chat view to actually pivot to real session data, which is
/// queued as part of the iOS broadcast UI work in v1.2).
private struct IOSChatHistorySheet: View {
    @Environment(\.tahoe) private var t
    var sessions: [AgentSession]
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
                        Button(action: onDismiss) {
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

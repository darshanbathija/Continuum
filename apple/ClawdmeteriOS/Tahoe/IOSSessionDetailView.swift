import SwiftUI
import ClawdmeterShared

/// iOS Session Detail — pushed from the Code list. Nav bar chip + thread +
/// PlanHaloMini + composer. Ports `ios-other.jsx::IOSSessionDetail`.
///
/// v0.12 button-wiring pass: the plan halo Refine / Approve & run buttons
/// and the composer Send button now reach the real daemon via
/// `AgentControlClient.approvePlan` / `sendPrompt`. Composer is a real
/// `TextField` (was a placeholder `Text` label), and pull-to-refresh
/// wires `agentClient.refreshAll()`.
/// v16 Code V2 workbench tabs. Each tab maps onto one of the six panes
/// that previously existed as standalone files but were never embedded.
/// Persisted per-session in `UserDefaults` so re-opening a session
/// returns to the last viewed tab.
enum SessionWorkbenchTab: String, CaseIterable, Identifiable {
    case chat, plan, diff, pr, terminal, artifacts
    var id: String { rawValue }

    var label: String {
        switch self {
        case .chat: return "Chat"
        case .plan: return "Plan"
        case .diff: return "Diff"
        case .pr: return "PR"
        case .terminal: return "Term"
        case .artifacts: return "Files"
        }
    }

    var icon: String {
        switch self {
        case .chat: return "bubble.left.and.bubble.right"
        case .plan: return "list.bullet.rectangle"
        case .diff: return "doc.text.magnifyingglass"
        case .pr: return "arrow.triangle.merge"
        case .terminal: return "terminal"
        case .artifacts: return "doc.richtext"
        }
    }
}

public struct IOSSessionDetailView: View {
    @Environment(\.tahoe) private var t
    @ObservedObject var agentClient: AgentControlClient
    /// v0.26 follow-up: app-scoped mobile command outbox owned by
    /// `IOSRootView`. Receive as `@ObservedObject` (not `@StateObject`)
    /// so a session detail navigation doesn't create a fresh outbox per
    /// view — the single app-scoped queue serves every session and the
    /// persisted `outbox.json` is never raced by sibling instances.
    @ObservedObject var outbox: MobileCommandOutbox
    var sessionId: UUID
    var data: TahoeCodeBindings
    var onBack: () -> Void

    @State private var composerText: String = ""
    @State private var sending: Bool = false
    @State private var refineAlertShown: Bool = false
    @State private var refineText: String = ""
    @State private var lastError: String?
    @State private var configSheetPresented: Bool = false
    @State private var outboxSheetPresented: Bool = false
    @State private var selectedTab: SessionWorkbenchTab
    @StateObject private var chatStore: iOSChatStore

    public init(
        agentClient: AgentControlClient,
        outbox: MobileCommandOutbox,
        sessionId: UUID,
        data: TahoeCodeBindings,
        onBack: @escaping () -> Void
    ) {
        self.agentClient = agentClient
        self.outbox = outbox
        self.sessionId = sessionId
        self.data = data
        self.onBack = onBack
        _chatStore = StateObject(wrappedValue: iOSChatStore(sessionId: sessionId, client: agentClient))
        // Restore last-selected tab per session. Chat is the default for
        // a freshly opened session.
        let stored = UserDefaults.standard.string(forKey: "clawdmeter.ios.session.\(sessionId).tab")
        _selectedTab = State(initialValue: SessionWorkbenchTab(rawValue: stored ?? "chat") ?? .chat)
    }

    /// Find the session this screen represents. Returns nil if it was
    /// archived/removed while the detail was open — in which case we render
    /// a graceful empty state and let the user back out.
    private var session: TahoeCodeSession? {
        for repo in data.repos {
            if let s = repo.sessions.first(where: { $0.id == sessionId }) { return s }
        }
        return nil
    }

    /// Parsed plan steps from the real session, when present. Used by the
    /// PlanHalo mini card. Demo bindings fall back to the JSX fixture plan.
    private var planSteps: [String] {
        if let raw = session?.runtimePlanText, !raw.isEmpty {
            let parsed = TahoePlanParser.steps(from: raw, cap: 8)
            if !parsed.isEmpty { return parsed }
        }
        return data.isDemo ? TahoeDemo.plan : []
    }

    /// True when this session has a real plan that can be approved.
    /// Disables Approve & run otherwise so users don't fire a no-op.
    private var hasRealPlan: Bool {
        guard let raw = session?.runtimePlanText else { return false }
        return !raw.isEmpty && session?.status == .planning
    }

    private var realAgentSession: AgentSession? {
        agentClient.sessions.first { $0.id == sessionId }
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Custom nav bar — title chip shows real session metadata.
            HStack(spacing: 10) {
                Button(action: onBack) {
                    TahoeIcon("chevL", size: 16).foregroundStyle(t.fg)
                        .frame(width: 40, height: 38)
                        .background { Capsule().fill(t.glassTintHi) }
                        .overlay { Capsule().stroke(t.hairline, lineWidth: 0.5) }
                }
                .buttonStyle(.plain)

                TahoeGlass(radius: 14, tone: .chip) {
                    HStack(spacing: 9) {
                        TahoeProviderGlyph(provider: session?.agent ?? .claude, size: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(session?.title ?? "Session unavailable")
                                .font(TahoeFont.body(12.5, weight: .bold))
                                .foregroundStyle(t.fg)
                                .lineLimit(1)
                            HStack(spacing: 4) {
                                Circle().fill(statusColor(session?.status ?? .done))
                                    .frame(width: 7, height: 7)
                                    .shadow(color: (session?.status == .running) ? statusColor(.running) : .clear, radius: 3, x: 0, y: 0)
                                Text(session?.subtitle ?? "—")
                                    .font(TahoeFont.body(10.5))
                                    .foregroundStyle(t.fg3)
                            }
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                }
                .frame(maxWidth: .infinity)

                // v16 outbox badge — taps open the per-session outbox pane.
                if outboxBadgeCount > 0 {
                    Button {
                        outboxSheetPresented = true
                    } label: {
                        ZStack {
                            Capsule().fill(t.glassTintHi)
                            Capsule().stroke(t.hairline, lineWidth: 0.5)
                            HStack(spacing: 4) {
                                Image(systemName: "tray.and.arrow.up")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(t.accent)
                                Text("\(outboxBadgeCount)")
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(t.fg)
                            }
                            .padding(.horizontal, 10)
                        }
                        .frame(height: 38)
                    }
                    .buttonStyle(.plain)
                }

                if session != nil && !data.isDemo {
                    IOSRoundIconBtn("sliders", action: openConfigSheet)
                } else if data.isDemo {
                    IOSRoundIconBtn("sliders")
                }
            }
            .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 12)

            // v16 workbench tab strip. Hidden in demo mode (the demo
            // bindings only stub the chat thread) and when no session
            // is found (we just show the empty state in the chat tab).
            if !data.isDemo, session != nil {
                tabChipStrip
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            // v16 tab body. Each branch renders the pane for the current
            // tab. Chat keeps its custom thread + composer; the other
            // five wrap the standalone pane views that previously
            // existed but were never embedded.
            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Composer — only relevant in the Chat tab. Other tabs have
            // their own write actions (plan: approve; PR: merge;
            // terminal: keystroke; artifacts: download).
            if selectedTab == .chat {
                TahoeGlass(radius: 22, tone: .raised) {
                    HStack(spacing: 8) {
                        TextField(composerPlaceholder, text: $composerText, axis: .vertical)
                            .font(TahoeFont.body(14))
                            .foregroundStyle(t.fg)
                            .lineLimit(1...4)
                            .textInputAutocapitalization(.sentences)
                            .submitLabel(.send)
                            .disabled(session == nil && !data.isDemo)
                        Spacer(minLength: 4)
                        Button(action: { Task { await sendComposer() } }) {
                            ZStack {
                                Circle().fill(LinearGradient(colors: [t.accent, t.accentDeepC],
                                                             startPoint: .top, endPoint: .bottom))
                                if sending {
                                    ProgressView()
                                        .progressViewStyle(.circular)
                                        .tint(.white)
                                } else {
                                    TahoeIcon("arrowU", size: 16, weight: .bold).foregroundStyle(.white)
                                }
                            }
                            .frame(width: 38, height: 38)
                            .shadow(color: t.accentDeep.color(opacity: 0.30), radius: 6, x: 0, y: 4)
                            .opacity(canSend ? 1.0 : 0.45)
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSend || sending)
                    }
                    .padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 10)
                }
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 14)
            }
        }
        .alert("Refine the plan", isPresented: $refineAlertShown) {
            TextField("What should change?", text: $refineText)
                .textInputAutocapitalization(.sentences)
            Button("Send", action: { Task { await sendRefine() } })
                .disabled(refineText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel, action: { refineText = "" })
        } message: {
            Text("Your message is sent to the agent as a plan-mode follow-up. The agent revises the plan and you re-approve.")
        }
        .alert("Couldn't send",
               isPresented: Binding(
                get: { lastError != nil },
                set: { if !$0 { lastError = nil } }
               ),
               actions: { Button("OK", role: .cancel) { lastError = nil } },
               message: { Text(lastError ?? "") })
        .sheet(isPresented: $configSheetPresented) {
            NavigationStack {
                if let realAgentSession {
                    iOSSessionControlsStrip(session: realAgentSession, client: agentClient)
                        .navigationTitle("Session controls")
                        .navigationBarTitleDisplayMode(.inline)
                } else {
                    ContentUnavailableView("Session unavailable", systemImage: "exclamationmark.triangle")
                }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $outboxSheetPresented) {
            NavigationStack {
                iOSOutboxPane(outbox: outbox, sessionId: sessionId)
                    .navigationTitle("Outbox")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium, .large])
        }
        .task(id: sessionId) {
            await chatStore.refresh()
            chatStore.start()
        }
        .onChange(of: selectedTab) { _, newValue in
            UserDefaults.standard.set(newValue.rawValue, forKey: "clawdmeter.ios.session.\(sessionId).tab")
        }
        .onDisappear {
            chatStore.stop()
        }
    }

    // MARK: - Tab UI

    /// Visible tabs change with session state. Plan only when there's a
    /// plan; PR only when the session has a worktree; Terminal only when
    /// at least one tmux pane exists; Artifacts only when the session
    /// snapshot lists at least one artifact entry.
    private var visibleTabs: [SessionWorkbenchTab] {
        var tabs: [SessionWorkbenchTab] = [.chat]
        if let s = realAgentSession {
            if let plan = s.planText, !plan.isEmpty {
                tabs.append(.plan)
            } else if s.status == .planning {
                tabs.append(.plan)
            }
            tabs.append(.diff)
            // Show PR + Terminal eagerly so the user can navigate to
            // them when empty (the pane handles its own empty state).
            tabs.append(.pr)
            if !s.terminalPanes.isEmpty {
                tabs.append(.terminal)
            }
            if !chatStore.snapshot.artifactEntries.isEmpty {
                tabs.append(.artifacts)
            }
        }
        return tabs
    }

    @ViewBuilder
    private var tabChipStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(visibleTabs) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 12, weight: .medium))
                            Text(tab.label)
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background {
                            Capsule().fill(selectedTab == tab ? t.accent : t.glassTintHi)
                        }
                        .overlay {
                            Capsule().stroke(selectedTab == tab ? .clear : t.hairline, lineWidth: 0.5)
                        }
                        .foregroundStyle(selectedTab == tab ? .white : t.fg)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .chat:
            chatPane
        case .plan:
            if let s = realAgentSession {
                iOSPlanTrackerView(session: s, onApprove: { await approvePlan() })
            } else {
                emptyState(title: "No session", body: "Session unavailable.")
            }
        case .diff:
            if let s = realAgentSession {
                iOSDiffView(session: s, client: agentClient)
            } else {
                emptyState(title: "No session", body: "Session unavailable.")
            }
        case .pr:
            if let s = realAgentSession {
                iOSPRPane(session: s, client: agentClient)
            } else {
                emptyState(title: "No session", body: "Session unavailable.")
            }
        case .terminal:
            if let s = realAgentSession {
                iOSTerminalTabsView(client: agentClient, session: s)
            } else {
                emptyState(title: "No session", body: "Session unavailable.")
            }
        case .artifacts:
            if let s = realAgentSession {
                iOSArtifactsPane(client: agentClient, session: s, chatStore: chatStore)
            } else {
                emptyState(title: "No session", body: "Session unavailable.")
            }
        }
    }

    /// Pre-tabs body content, unchanged. Renders the chat thread + plan
    /// halo inline so the existing UX stays intact when the user opens
    /// a session and stays on the Chat tab.
    @ViewBuilder
    private var chatPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if data.isDemo {
                    ForEach(Array(TahoeDemo.thread.enumerated()), id: \.offset) { _, msg in
                        IOSThreadMsg(msg: msg, providerOverride: session?.agent)
                    }
                    IOSPlanHaloMini(
                        steps: planSteps,
                        canApprove: true,
                        onRefine: { refineAlertShown = true },
                        onApprove: { Task { await approvePlan() } }
                    )
                } else if session == nil {
                    emptyState(
                        title: "Session unavailable",
                        body: "This session may have been archived on your Mac. Go back to see what's still running."
                    )
                } else if chatStore.snapshot.items.isEmpty {
                    emptyState(
                        title: "No transcript yet",
                        body: "Messages appear here after the Mac publishes this session's chat snapshot."
                    )
                    if !planSteps.isEmpty {
                        IOSPlanHaloMini(
                            steps: planSteps,
                            canApprove: hasRealPlan,
                            onRefine: { refineAlertShown = true },
                            onApprove: { Task { await approvePlan() } }
                        )
                    }
                } else {
                    ForEach(chatStore.snapshot.items) { item in
                        IOSWireChatItemRow(item: item, provider: session?.agent ?? .claude)
                    }
                    if !planSteps.isEmpty {
                        IOSPlanHaloMini(
                            steps: planSteps,
                            canApprove: hasRealPlan,
                            onRefine: { refineAlertShown = true },
                            onApprove: { Task { await approvePlan() } }
                        )
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 4)
        }
        .refreshable {
            await agentClient.refreshAll()
        }
    }

    /// Combined pending + failed count for this session; drives the nav
    /// bar badge that opens the per-session outbox pane.
    private var outboxBadgeCount: Int {
        outbox.pending.filter { $0.sessionId == sessionId }.count
            + outbox.failed.filter { $0.sessionId == sessionId }.count
    }

    // MARK: - Computed UX state

    private var composerPlaceholder: String {
        if data.isDemo { return "Refine the plan…" }
        if session == nil { return "Session unavailable" }
        return "Send a follow-up…"
    }

    private var canSend: Bool {
        guard session != nil else { return false }
        return !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Actions

    @MainActor
    private func sendComposer() async {
        let trimmed = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, session != nil else { return }
        // Demo bindings short-circuit — clear the text but don't hit the
        // wire (the demo session id wouldn't resolve on the daemon side).
        if data.isDemo {
            composerText = ""
            return
        }
        // v0.26 follow-up: route through outbox so retries dedup via the
        // wire-v16 idempotency contract, offline sends queue + retry
        // with exp backoff, and failures surface in the per-session
        // outbox badge instead of getting silently swallowed. Clear
        // composer immediately — the outbox owns delivery from here
        // on, and a stuck delivery is now visible in the queue UI
        // rather than holding the composer hostage.
        outbox.enqueueSend(sessionId: sessionId, text: trimmed, asFollowUp: true)
        composerText = ""
    }

    @MainActor
    private func sendRefine() async {
        let trimmed = refineText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, session != nil, !data.isDemo else { return }
        // Same routing rationale as sendComposer — refine is just a
        // send tagged as a plan-mode follow-up.
        outbox.enqueueSend(sessionId: sessionId, text: trimmed, asFollowUp: true)
        refineText = ""
    }

    @MainActor
    private func approvePlan() async {
        guard session != nil else { return }
        guard !data.isDemo else { return }  // demo plan, no real id to approve
        outbox.enqueueApprovePlan(sessionId: sessionId)
    }

    private func openConfigSheet() {
        configSheetPresented = true
    }

    private func statusColor(_ s: TahoeCodeSession.Status) -> Color {
        switch s {
        case .running:  return Color(.sRGB, red: 0x28/255.0, green: 0xC8/255.0, blue: 0x40/255.0)
        case .planning: return t.fg3
        case .paused:   return Color(.sRGB, red: 0xFE/255.0, green: 0xBC/255.0, blue: 0x2E/255.0)
        case .done:     return t.accent
        case .degraded: return Color(.sRGB, red: 1, green: 0x5F/255.0, blue: 0x57/255.0)
        }
    }

    @ViewBuilder
    private func emptyState(title: String, body: String) -> some View {
        VStack(spacing: 8) {
            TahoeIcon("chat", size: 22).foregroundStyle(t.fg4)
            Text(title)
                .font(TahoeFont.body(14, weight: .semibold))
                .foregroundStyle(t.fg2)
            Text(body)
                .font(TahoeFont.body(12))
                .foregroundStyle(t.fg3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 300)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

private struct IOSWireChatItemRow: View {
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
                    HStack(spacing: 8) {
                        TahoeIcon("doc", size: 11).foregroundStyle(t.fg3)
                        Text(pair.call.title)
                            .font(TahoeFont.body(11.5, weight: .semibold))
                            .foregroundStyle(t.fg2)
                        Text(pair.call.body)
                            .font(TahoeFont.mono(11))
                            .foregroundStyle(pair.call.isError ? .red : t.fg3)
                            .lineLimit(2)
                        Spacer()
                    }
                    .padding(.horizontal, 4).padding(.vertical, 4)
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
                TahoeGlass(radius: 20, tone: .raised) {
                    Text(message.body)
                        .font(TahoeFont.body(13))
                        .foregroundStyle(t.fg)
                        .padding(.horizontal, 15).padding(.vertical, 11)
                        .fixedSize(horizontal: false, vertical: true)
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
        case .meta:
            Text(message.body)
                .font(TahoeFont.body(11.5))
                .foregroundStyle(t.fg3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct IOSThreadMsg: View {
    @Environment(\.tahoe) private var t
    var msg: TahoeDemo.DemoThreadMsg
    /// Real session's provider, when available. Lets the demo placeholder
    /// pick up the actual agent's glyph instead of always rendering Claude.
    var providerOverride: TahoeProvider?

    var body: some View {
        switch msg {
        case .user(let text):
            HStack {
                Spacer()
                TahoeGlass(radius: 20, tone: .raised) {
                    Text(text)
                        .font(TahoeFont.body(13))
                        .foregroundStyle(t.fg)
                        .padding(.horizontal, 15).padding(.vertical, 11)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity * 0.82, alignment: .trailing)
            }
        case .tool(let tool, let target, _):
            HStack(spacing: 8) {
                TahoeIcon(tool == "grep" ? "search" : "doc", size: 11).foregroundStyle(t.fg3)
                Text(tool).font(TahoeFont.body(11.5, weight: .semibold)).foregroundStyle(t.fg2)
                Text(target).font(TahoeFont.mono(11)).foregroundStyle(t.fg3).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 4).padding(.vertical, 4)
        case .assistant(let text):
            HStack(alignment: .top, spacing: 9) {
                TahoeProviderGlyph(provider: providerOverride ?? .claude, size: 24)
                Text(text)
                    .font(TahoeFont.body(14))
                    .foregroundStyle(t.fg)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
        }
    }
}

private struct IOSPlanHaloMini: View {
    @Environment(\.tahoe) private var t
    /// Plan steps to render. Pre-parsed by the parent — empty means hide.
    var steps: [String]
    /// Whether Approve & run is enabled. False when the session is not
    /// actually in plan-mode (the daemon would reject a no-op approval).
    var canApprove: Bool
    var onRefine: () -> Void
    var onApprove: () -> Void

    var body: some View {
        if steps.isEmpty {
            EmptyView()
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(RadialGradient(
                        colors: [t.accentGlow.color(opacity: 0.30), .clear],
                        center: UnitPoint(x: 0.5, y: 0.3), startRadius: 0, endRadius: 400))
                    .blur(radius: 6).padding(-20).allowsHitTesting(false)

                TahoeGlass(radius: 20, tone: .raised) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(LinearGradient(colors: [t.accent, t.accentDeepC],
                                                     startPoint: .top, endPoint: .bottom))
                                .frame(width: 26, height: 26)
                                .overlay { TahoeIcon("sparkles", size: 13).foregroundStyle(.white) }
                                .shadow(color: t.accentDeep.color(opacity: 0.35), radius: 6, x: 0, y: 4)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("PLAN READY")
                                    .font(TahoeFont.body(11, weight: .bold))
                                    .tracking(0.4)
                                    .foregroundStyle(t.fg3)
                                Text("\(steps.count) step\(steps.count == 1 ? "" : "s")")
                                    .font(TahoeFont.body(13, weight: .bold))
                                    .foregroundStyle(t.fg)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 4)

                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(steps.prefix(3).enumerated()), id: \.offset) { i, step in
                                HStack(alignment: .top, spacing: 9) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 5, style: .continuous).fill(t.hair2)
                                        Text("\(i+1)").font(TahoeFont.mono(10, weight: .bold)).foregroundStyle(t.fg2)
                                    }
                                    .frame(width: 18, height: 18)
                                    Text(step)
                                        .font(TahoeFont.body(12.5))
                                        .foregroundStyle(t.fg)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            if steps.count > 3 {
                                Text("+ \(steps.count - 3) more step\(steps.count - 3 == 1 ? "" : "s")…")
                                    .font(TahoeFont.body(11.5))
                                    .foregroundStyle(t.fg3)
                                    .padding(.leading, 27)
                            }
                        }
                        .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 12)

                        TahoeHair()

                        HStack(spacing: 8) {
                            TahoeGhostButton(size: .l, action: onRefine) { Text("Refine") }
                                .frame(maxWidth: .infinity)
                            TahoeAccentButton(size: .l, action: onApprove) { Text("Approve & run") }
                                .frame(maxWidth: .infinity * 2)
                                .opacity(canApprove ? 1.0 : 0.5)
                                .disabled(!canApprove)
                        }
                        .padding(10)
                    }
                }
            }
            .padding(.top, 4)
        }
    }
}

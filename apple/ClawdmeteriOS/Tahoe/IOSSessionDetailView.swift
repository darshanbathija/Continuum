import SwiftUI
import PhotosUI
import ClawdmeterShared
#if canImport(UIKit)
import UIKit
#endif

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
    case chat, plan, diff, sources, browser, pr, terminal, artifacts
    var id: String { rawValue }

    var label: String {
        switch self {
        case .chat: return "Chat"
        case .plan: return "Plan"
        case .diff: return "Diff"
        case .sources: return "Sources"
        case .browser: return "Run"
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
        case .sources: return "link"
        case .browser: return "safari"
        case .pr: return "arrow.triangle.merge"
        case .terminal: return "terminal"
        case .artifacts: return "doc.richtext"
        }
    }
}

private struct IOSQueuedCodeDraft: Codable, Equatable, Identifiable {
    let id: UUID
    let sessionId: UUID
    var text: String
    let createdAt: Date

    init(id: UUID = UUID(), sessionId: UUID, text: String, createdAt: Date = Date()) {
        self.id = id
        self.sessionId = sessionId
        self.text = text
        self.createdAt = createdAt
    }
}

public struct IOSSessionDetailView: View {
    @Environment(\.tahoe) private var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var agentClient: AgentControlClient
    /// v0.26 follow-up: app-scoped mobile command outbox owned by
    /// `IOSRootView`. Receive as `@ObservedObject` (not `@StateObject`)
    /// so a session detail navigation doesn't create a fresh outbox per
    /// view — the single app-scoped queue serves every session and the
    /// persisted `outbox.json` is never raced by sibling instances.
    @ObservedObject var outbox: MobileCommandOutbox
    @ObservedObject var presentationStore: SessionPresentationStore
    var sessionId: UUID
    var data: TahoeCodeBindings
    var onOpenSession: (UUID) -> Void
    var onBack: () -> Void

    @State private var composerText: String = ""
    /// v0.26.2 review: rapid-tap guard for Approve. The composer
    /// uses optimistic-clear as a de-facto guard (cleared text flips
    /// `canSend` off). Approve has no equivalent — its `canApprove`
    /// flag depends on async WS-pushed session state, leaving a
    /// race window where a double-tap enqueues two envelopes with
    /// distinct idempotency keys. The second hits a respawned
    /// session and surfaces as a `.failed` envelope. Local flag
    /// closes the window.
    @State private var approving: Bool = false
    @State private var isRetrying: Bool = false
    @State private var refineAlertShown: Bool = false
    @State private var refineText: String = ""
    @State private var lastError: String?
    @State private var configSheetPresented: Bool = false
    @State private var checkpointsSheetPresented: Bool = false
    @State private var outboxSheetPresented: Bool = false
    @State private var selectedTab: SessionWorkbenchTab
    @State private var queuedDrafts: [IOSQueuedCodeDraft]
    @State private var isDispatchingQueuedDraft: Bool = false
    @State private var dispatchedQueuedTurnForCurrentIdle: Bool = false
    @State private var chatPanePinned: Bool = true
    @State private var hostRunMinutes: HostRunMinutesResponse?
    @State private var expandedTranscriptTurns: Set<String> = []
    @State private var projectionCache = SingleSlotProjectionCache<TranscriptProjectionCacheKey, TranscriptProjection>()
    @State private var attachments: [ComposerAttachment] = []
    @State private var photoPickerItems: [PhotosPickerItem] = []
    @State private var documentTabs: [IOSWorkspaceDocumentTab] = []
    @State private var selectedDocumentTabId: UUID?
    @StateObject private var chatStore: iOSChatStore
    #if DEBUG && canImport(UIKit)
    @StateObject private var scrollPerfProbe = IOSScrollPerformanceProbe()
    #endif

    public init(
        agentClient: AgentControlClient,
        outbox: MobileCommandOutbox,
        sessionId: UUID,
        data: TahoeCodeBindings,
        presentationStore: SessionPresentationStore,
        onOpenSession: @escaping (UUID) -> Void = { _ in },
        onBack: @escaping () -> Void
    ) {
        self.agentClient = agentClient
        self.outbox = outbox
        self.presentationStore = presentationStore
        self.sessionId = sessionId
        self.data = data
        self.onOpenSession = onOpenSession
        self.onBack = onBack
        let args = ProcessInfo.processInfo.arguments
        _chatStore = StateObject(wrappedValue: iOSChatStore(sessionId: sessionId, client: agentClient))
        // Restore last-selected tab per session. Chat is the default for
        // a freshly opened session.
        let stored = UserDefaults.standard.string(forKey: "clawdmeter.ios.session.\(sessionId).tab")
        let requestedTab = Self.screenshotTab(from: args)
        _selectedTab = State(initialValue: requestedTab ?? SessionWorkbenchTab(rawValue: stored ?? "chat") ?? .chat)
        _queuedDrafts = State(initialValue: Self.loadQueuedDrafts(sessionId: sessionId))
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

    /// True when this session has a daemon-backed planning state that can be
    /// approved. Claude/Gemini usually provide `planText`; Codex exposes
    /// structured todos and the daemon accepts approval for planning Codex
    /// sessions even when `planText` is empty.
    private var hasRealPlan: Bool {
        guard let realAgentSession, realAgentSession.status == .planning else { return false }
        if realAgentSession.agent == .codex { return true }
        if let raw = realAgentSession.planText, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        if let raw = session?.runtimePlanText, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return false
    }

    private var realAgentSession: AgentSession? {
        agentClient.sessions.first { $0.id == sessionId }
    }

    private var navigationSubtitle: String {
        guard let realAgentSession else { return session?.subtitle ?? "—" }
        let status = session?.subtitle ?? realAgentSession.status.rawValue
        let model = effectiveModelId(for: realAgentSession) ?? "default"
        var parts = ["\(status) · \(model) · \(effortText(for: realAgentSession))"]
        if let label = realAgentSession.executionHostLabel {
            if let minutes = hostRunMinutes?.billableMinutes(forSession: sessionId), minutes > 0 {
                parts.append("Running on \(label) · \(minutes) min")
            } else {
                parts.append("Running on \(label)")
            }
        }
        return parts.joined(separator: " · ")
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Custom nav bar — title chip shows real session metadata.
            HStack(spacing: 10) {
                Button(action: ContinuumAnalytics.wrapButton("session_back", onBack)) {
                    TahoeIcon("chevL", size: 16).foregroundStyle(t.fg)
                        .frame(width: 40, height: 38)
                        .background { Capsule().fill(t.glassTintHi) }
                        .overlay { Capsule().stroke(t.hairline, lineWidth: 0.5) }
                }
                .buttonStyle(.plain)

                TahoeGlass(radius: 6, tone: .chip) {
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
                                Text(navigationSubtitle)
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

                if session != nil {
                    sessionMenuButton
                }
            }
            .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 12)

            if let realAgentSession,
               let workspaceKey = WorkspaceKey.of(realAgentSession) {
                IOSWorkspaceTabStrip(
                    workspaceKey: workspaceKey,
                    sessions: agentClient.sessions,
                    activeSessionId: realAgentSession.id,
                    terminalAvailable: hasTerminalSurface(realAgentSession),
                    documentTabs: documentTabs,
                    activeDocumentTabId: selectedDocumentTab?.id,
                    onOpenSession: { id in
                        selectedDocumentTabId = nil
                        onOpenSession(id)
                    },
                    onOpenTerminal: {
                        selectedDocumentTabId = nil
                        if visibleTabs.contains(.terminal) {
                            selectTab(.terminal)
                        }
                    },
                    onSelectDocument: { selectDocumentTab($0) },
                    onCloseDocument: { closeDocumentTab($0) }
                )
                .padding(.bottom, 6)
            }

            // The workbench tabs are real panes, not a hidden menu item:
            // Plan, Run, PR, and Terminal are directly reachable from the
            // detail screen and preserve their existing daemon-backed views.
            if selectedDocumentTab == nil {
                tabChipStrip
                    .padding(.bottom, 8)
            }

            // v16 tab body. Each branch renders the pane for the current
            // tab. Chat keeps its custom thread + composer; the other
            // five wrap the standalone pane views that previously
            // existed but were never embedded.
            if let documentTab = selectedDocumentTab {
                IOSMarkdownDocumentTabView(
                    tab: documentTab,
                    sessionId: documentTab.sessionId,
                    client: agentClient
                )
                .id(documentTab.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                tabContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // Composer — only relevant in the Chat tab. Other tabs have
            // their own write actions (plan: approve; PR: merge;
            // terminal: keystroke; artifacts: download).
            if selectedDocumentTab == nil && selectedTab == .chat {
                if !queuedDrafts.isEmpty {
                    queuedDraftsPanel
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                }
                TahoeGlass(radius: isPlanApprovalMode ? 18 : 22, tone: .raised) {
                    VStack(alignment: .leading, spacing: isPlanApprovalMode ? 6 : 8) {
                        if !attachments.isEmpty {
                            attachmentStrip
                        }
                        if !composerChips.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    ForEach(composerChips, id: \.id) { chip in
                                        composerChip(chip)
                                    }
                                }
                            }
                        }
                        HStack(spacing: 8) {
                            TextField(composerPlaceholder, text: $composerText, axis: .vertical)
                                .font(TahoeFont.body(14))
                                .foregroundStyle(t.fg)
                                .lineLimit(isPlanApprovalMode ? 1...2 : 1...4)
                                .textInputAutocapitalization(.sentences)
                                .submitLabel(.send)
                            .disabled(session == nil && !data.isDemo)
                            Spacer(minLength: 4)
                            attachButton
                            Button(action: ContinuumAnalytics.wrapButton(
                                    "send_composer",
                                    {
 Task { await sendComposer() } 
                                    }
                                )) {
                                ZStack {
                                    Circle().fill(sendButtonFill)
                                    if isDispatchingQueuedDraft {
                                        ProgressView().controlSize(.mini)
                                    } else {
                                        TahoeIcon(isSessionRunning ? "tray" : "arrowU", size: 16, weight: .bold)
                                            .foregroundStyle(.white)
                                    }
                                }
                                .frame(width: 38, height: 38)
                                .shadow(color: t.accentDeep.color(opacity: 0.30), radius: 6, x: 0, y: 4)
                                .opacity(canSend ? 1.0 : 0.45)
                            }
                            .buttonStyle(.plain)
                            .disabled(!canSend)
                        }
                    }
                    .padding(.leading, 14).padding(.trailing, 8).padding(.vertical, isPlanApprovalMode ? 7 : 10)
                }
                .padding(.horizontal, 12).padding(.top, isPlanApprovalMode ? 6 : 10).padding(.bottom, isPlanApprovalMode ? 10 : 14)
            }
        }
        .alert("Refine the plan", isPresented: $refineAlertShown) {
            TextField("What should change?", text: $refineText)
                .textInputAutocapitalization(.sentences)
            Button("Send", action: ContinuumAnalytics.wrapButton(
                    "send",
                    {
 Task { await sendRefine() } 
                    }
                ))
                .disabled(refineText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel, action: ContinuumAnalytics.wrapButton("refine_cancel", { refineText = "" }))
        } message: {
            Text("Your message is sent to the agent as a plan-mode follow-up. The agent revises the plan and you re-approve.")
        }
        .alert("Couldn't send",
               isPresented: Binding(
                get: { lastError != nil },
                set: { if !$0 { lastError = nil } }
               ),
               actions: { Button("OK", role: .cancel, action: ContinuumAnalytics.wrapButton(
                       "ok",
                       {
 lastError = nil 
                       }
                   )) },
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
        .sheet(isPresented: $checkpointsSheetPresented) {
            NavigationStack {
                if let realAgentSession {
                    iOSCheckpointPane(client: agentClient, session: realAgentSession)
                        .navigationTitle("Checkpoints")
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
            #if DEBUG
            if agentClient.codeTabVerificationChatSnapshot(sessionId: sessionId) != nil {
                return
            }
            #endif
            await chatStore.refresh()
            chatStore.start()
        }
        .task {
            guard agentClient.supportsExecutionHosts else { return }
            hostRunMinutes = await agentClient.refreshHostRunMinutes()
        }
        .onChange(of: selectedTab) { _, newValue in
            UserDefaults.standard.set(newValue.rawValue, forKey: "clawdmeter.ios.session.\(sessionId).tab")
        }
        .onChange(of: photoPickerItems) { _, newItems in
            Task { await ingestPhotoPickerItems(newItems) }
        }
        .onChange(of: realAgentSession?.status) { oldValue, newValue in
            if newValue == .running {
                dispatchedQueuedTurnForCurrentIdle = false
            } else if oldValue == .running {
                dispatchedQueuedTurnForCurrentIdle = false
            }
        }
        .task(id: queueDrainKey) {
            await drainQueuedDraftsIfPossible()
        }
        .onDisappear {
            chatStore.stop()
        }
    }

    // MARK: - Tab UI

    private var selectedDocumentTab: IOSWorkspaceDocumentTab? {
        guard let id = selectedDocumentTabId else { return nil }
        return documentTabs.first { $0.id == id }
    }

    private var sessionMenuButton: some View {
        Menu {
            if !data.isDemo {
                Button {
                    openConfigSheet()
                } label: {
                    Label("Session settings", systemImage: "slider.horizontal.3")
                }
                Button {
                    checkpointsSheetPresented = true
                } label: {
                    Label("Checkpoints", systemImage: "bookmark")
                }
                Divider()
            }
            ForEach(visibleTabs) { tab in
                Button {
                    selectTab(tab)
                } label: {
                    Label(tab.label, systemImage: tab.icon)
                }
            }
        } label: {
            TahoeIcon("sliders", size: 16)
                .foregroundStyle(t.fg)
                .frame(width: 40, height: 38)
                .background {
                    Capsule(style: .continuous).fill(t.glassTintHi)
                }
                .overlay {
                    Capsule(style: .continuous).stroke(t.hairline, lineWidth: 0.5)
                }
        }
        .buttonStyle(.plain)
    }

    /// Visible tabs change with session state. Plan only when there's a
    /// plan; all backed review panes stay visible so empty states do not
    /// hide working controls or make the tab set jump as data arrives.
    private var visibleTabs: [SessionWorkbenchTab] {
        var tabs: [SessionWorkbenchTab] = [.chat]
        if let s = realAgentSession {
            if s.agent == .codex {
                tabs.append(.plan)
            } else if s.agent == .gemini && agentClient.supportsAntigravityPlan {
                tabs.append(.plan)
            } else if let plan = s.planText, !plan.isEmpty {
                tabs.append(.plan)
            } else if let plan = s.approvedPlanText, !plan.isEmpty {
                tabs.append(.plan)
            } else if s.status == .planning {
                tabs.append(.plan)
            }
            tabs.append(.diff)
            tabs.append(.sources)
            tabs.append(.browser)
            // Show PR + Terminal eagerly so the user can navigate to
            // them when empty (the pane handles its own empty state).
            tabs.append(.pr)
            if hasTerminalSurface(s) { tabs.append(.terminal) }
            tabs.append(.artifacts)
        }
        return tabs
    }

    private var primaryTabs: [SessionWorkbenchTab] {
        let priority: [SessionWorkbenchTab] = [.chat, .plan, .diff, .browser]
        return priority.filter { visibleTabs.contains($0) }
    }

    private var overflowTabs: [SessionWorkbenchTab] {
        visibleTabs.filter { !primaryTabs.contains($0) }
    }

    @ViewBuilder
    private var tabChipStrip: some View {
        HStack(spacing: 4) {
            ForEach(primaryTabs) { tab in
                tabChip(tab)
            }

            if !overflowTabs.isEmpty {
                Menu {
                    ForEach(overflowTabs) { tab in
                        Button {
                            selectTab(tab)
                        } label: {
                            Label(tab.label, systemImage: tab.icon)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: overflowTabs.contains(selectedTab) ? selectedTab.icon : "ellipsis")
                            .font(.system(size: 12, weight: .medium))
                        Text(overflowTabs.contains(selectedTab) ? selectedTab.label : "More")
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)
                    .background {
                        Capsule().fill(overflowTabs.contains(selectedTab) ? t.accent : t.glassTintHi)
                    }
                    .overlay {
                        Capsule().stroke(overflowTabs.contains(selectedTab) ? .clear : t.hairline, lineWidth: 0.5)
                    }
                    .foregroundStyle(overflowTabs.contains(selectedTab) ? .white : t.fg)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private func tabChip(_ tab: SessionWorkbenchTab) -> some View {
        Button {
            selectTab(tab)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: tab.icon)
                    .font(.system(size: 12, weight: .medium))
                Text(tab.label)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 8)
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

    private func selectTab(_ tab: SessionWorkbenchTab) {
        if reduceMotion {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                selectedDocumentTabId = nil
                selectedTab = tab
            }
        } else {
            withAnimation(.snappy(duration: 0.18)) {
                selectedDocumentTabId = nil
                selectedTab = tab
            }
        }
    }

    private func selectDocumentTab(_ tab: IOSWorkspaceDocumentTab) {
        if reduceMotion {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                selectedDocumentTabId = tab.id
            }
        } else {
            withAnimation(.snappy(duration: 0.18)) {
                selectedDocumentTabId = tab.id
            }
        }
    }

    private func openMarkdownDocument(_ path: String) {
        guard let realAgentSession else { return }
        if reduceMotion {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                _ = IOSWorkspaceDocumentTabs.open(
                    tabs: &documentTabs,
                    selectedId: &selectedDocumentTabId,
                    session: realAgentSession,
                    path: path
                )
            }
        } else {
            withAnimation(.snappy(duration: 0.18)) {
                _ = IOSWorkspaceDocumentTabs.open(
                    tabs: &documentTabs,
                    selectedId: &selectedDocumentTabId,
                    session: realAgentSession,
                    path: path
                )
            }
        }
    }

    private func closeDocumentTab(_ tab: IOSWorkspaceDocumentTab) {
        let wasSelected = selectedDocumentTabId == tab.id
        if reduceMotion {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                IOSWorkspaceDocumentTabs.close(tabs: &documentTabs, selectedId: &selectedDocumentTabId, tab: tab)
                if wasSelected {
                    selectedTab = .chat
                }
            }
        } else {
            withAnimation(.snappy(duration: 0.18)) {
                IOSWorkspaceDocumentTabs.close(tabs: &documentTabs, selectedId: &selectedDocumentTabId, tab: tab)
                if wasSelected {
                    selectedTab = .chat
                }
            }
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .chat:
            chatPane
        case .plan:
            if let s = realAgentSession {
                planPane(for: s)
            } else {
                emptyState(title: "No session", body: "Session unavailable.")
            }
        case .diff:
            if let s = realAgentSession {
                iOSDiffView(session: s, client: agentClient)
            } else {
                emptyState(title: "No session", body: "Session unavailable.")
            }
        case .sources:
            iOSSourcesPane(chatStore: chatStore, outbox: outbox, sessionId: sessionId)
        case .browser:
            if let s = realAgentSession {
                iOSRunPreviewPane(
                    client: agentClient,
                    outbox: outbox,
                    session: s,
                    onOpenTerminal: {
                        if visibleTabs.contains(.terminal) {
                            selectTab(.terminal)
                        }
                    }
                )
            } else {
                emptyState(title: "No session", body: "Session unavailable.")
            }
        case .pr:
            if let s = realAgentSession {
                iOSPRPane(session: s, client: agentClient, outbox: outbox)
            } else {
                emptyState(title: "No session", body: "Session unavailable.")
            }
        case .terminal:
            if let s = realAgentSession, hasTerminalSurface(s) {
                iOSTerminalTabsView(client: agentClient, session: s, chatStore: chatStore)
            } else {
                emptyState(title: "Terminal unavailable", body: "This session does not expose a live terminal.")
            }
        case .artifacts:
            if let s = realAgentSession {
                iOSArtifactsPane(
                    client: agentClient,
                    session: s,
                    chatStore: chatStore,
                    onOpenMarkdownDocument: openMarkdownDocument
                )
            } else {
                emptyState(title: "No session", body: "Session unavailable.")
            }
        }
    }

    private static func screenshotTab(from args: [String]) -> SessionWorkbenchTab? {
        for arg in args {
            if arg.hasPrefix("--ios-code-demo-tab=") {
                let raw = String(arg.dropFirst("--ios-code-demo-tab=".count))
                return SessionWorkbenchTab(rawValue: raw)
            }
        }
        return nil
    }

    @ViewBuilder
    private func planPane(for session: AgentSession) -> some View {
        if session.agent == .codex {
            iOSCodexPlanView(
                chatStore: chatStore,
                canApprove: session.status == .planning && !approving,
                onApprove: { await approvePlan() }
            )
        } else if session.agent == .gemini && agentClient.supportsAntigravityPlan {
            iOSAntigravityPlanView(
                store: iOSAntigravityPlanStore(sessionId: session.id) { id in
                    try await agentClient.fetchAntigravityPlan(sessionId: id)
                }
            )
        } else {
            iOSPlanTrackerView(session: session, onApprove: { await approvePlan() })
        }
    }

    private func hasTerminalSurface(_ session: AgentSession) -> Bool {
        if session.tmuxPaneId != nil || session.tmuxWindowId != nil { return false }
        if let binding = session.runtimeBinding, !binding.capabilities.supportsTerminal { return false }
        return true
    }

    private static func isShellTool(_ title: String) -> Bool {
        let shellTools: Set<String> = ["bash", "shell", "exec", "exec_command", "sh", "zsh", "pwsh", "run", "execute"]
        return shellTools.contains(title.lowercased())
    }

    /// Pre-tabs body content, unchanged. Renders the chat thread + plan
    /// halo inline so the existing UX stays intact when the user opens
    /// a session and stays on the Chat tab.
    @ViewBuilder
    private var chatPane: some View {
        let projection = projectionCache.value(
            for: TranscriptProjectionCacheKey(
                updateCounter: chatStore.snapshot.updateCounter,
                mode: .latestAnswerOnly
            )
        ) {
            TranscriptTurnProjector.project(items: chatStore.snapshot.items, mode: .latestAnswerOnly)
        }
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if data.isDemo {
                            ForEach(Array(TahoeDemo.thread.enumerated()), id: \.offset) { _, msg in
                                IOSThreadMsg(msg: msg, providerOverride: session?.agent)
                            }
                            IOSPlanHaloMini(
                                steps: planSteps,
                                canApprove: !approving,
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
                                    canApprove: hasRealPlan && !approving,
                                    onRefine: { refineAlertShown = true },
                                    onApprove: { Task { await approvePlan() } }
                                )
                            }
                        } else {
                            ForEach(projection.turns.suffix(100)) { turn in
                                iosCollapsedTurnRow(turn)
                            }
                            if !planSteps.isEmpty {
                                IOSPlanHaloMini(
                                    steps: planSteps,
                                    canApprove: hasRealPlan && !approving,
                                    onRefine: { refineAlertShown = true },
                                    onApprove: { Task { await approvePlan() } }
                                )
                            }
                        }
                        Color.clear.frame(height: 1).id("ios-session-detail-bottom")
                    }
                    .padding(.horizontal, 16).padding(.vertical, 4)
                }
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    let visibleBottom = geometry.contentOffset.y + geometry.containerSize.height
                    return visibleBottom >= geometry.contentSize.height - 64
                } action: { _, isAtBottom in
                    chatPanePinned = isAtBottom
                }
                .onChange(of: chatStore.snapshot.updateCounter) { _, _ in
                    guard chatPanePinned else { return }
                    scrollChatPaneToBottom(proxy, animated: false)
                }
                .onAppear {
                    chatPanePinned = true
                    scrollChatPaneToBottom(proxy, animated: false)
                    #if DEBUG && canImport(UIKit)
                    scrollPerfProbe.start(
                        label: "IOSSessionDetailView.chatPane",
                        itemCount: chatStore.snapshot.items.count
                    )
                    #endif
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 80_000_000)
                        scrollChatPaneToBottom(proxy, animated: false)
                    }
                }
                .onDisappear {
                    #if DEBUG && canImport(UIKit)
                    scrollPerfProbe.stopAndLog(reason: "disappear")
                    #endif
                }
                if !chatPanePinned && !chatStore.snapshot.items.isEmpty {
                    Button {
                        scrollChatPaneToBottom(proxy, animated: true)
                    } label: {
                        Label("Latest", systemImage: "arrow.down.circle.fill")
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(ContinuumTokens.surface2, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 18)
                    .padding(.bottom, 14)
                }
            }
            .refreshable {
                await agentClient.refreshAll()
            }
        }
    }

    @ViewBuilder
    private func iosCollapsedTurnRow(_ turn: TranscriptTurn) -> some View {
        if turn.prompt == nil {
            ForEach(turn.visibleItems) { item in
                iosTranscriptItemRow(item)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(iosPromptItems(turn)) { item in
                    iosTranscriptItemRow(item)
                }
                iosDisclosureButton(turn)
                if turn.hasCollapsedContent, expandedTranscriptTurns.contains(turn.id) {
                    ForEach(turn.hiddenItems) { item in
                        iosTranscriptItemRow(item)
                    }
                }
                ForEach(iosFinalItems(turn)) { item in
                    iosTranscriptItemRow(item)
                }
                iosTurnChipStrip(turn)
            }
        }
    }

    private func iosTranscriptItemRow(_ item: ChatItem) -> some View {
        IOSWireChatItemRow(
            item: item,
            sessionId: sessionId,
            provider: session?.agent ?? .claude,
            presentationStore: presentationStore,
            onOpenMarkdownDocument: openMarkdownDocument,
            modelFailureRetryPrompt: modelFailureRetryPrompt(for: item),
            onRetryFailedTurn: isTranscriptReadOnly
                ? nil
                : { promptBody in
                    Task { await performTurnRetry(promptBody: promptBody) }
                },
            onRetryFailedTurnInNewChat: isTranscriptReadOnly
                ? nil
                : { promptBody in
                    Task { await performTurnRetryInNewChat(promptBody: promptBody) }
                }
        )
        .id(item.id)
    }

    private var isTranscriptReadOnly: Bool {
        data.isDemo || session == nil || realAgentSession?.archivedAt != nil
    }

    private func modelFailureRetryPrompt(for item: ChatItem) -> String? {
        guard case .message(let message) = item else { return nil }
        let retryPrompt = ModelFailureRecovery.retryPrompt(
            forErrorMessageId: message.id,
            in: chatStore.snapshot.items
        )
        guard ModelFailureRecovery.shouldOfferRetryActions(
            message: message,
            isStreamingTail: false,
            turnState: chatStore.snapshot.currentTurnState,
            isReadOnly: isTranscriptReadOnly,
            retryPrompt: retryPrompt
        ) else { return nil }
        return retryPrompt
    }

    private func iosPromptItems(_ turn: TranscriptTurn) -> [ChatItem] {
        guard let promptId = turn.prompt?.id else { return [] }
        return turn.visibleItems.filter {
            if case .message(let message) = $0 { return message.id == promptId }
            return false
        }
    }

    private func iosFinalItems(_ turn: TranscriptTurn) -> [ChatItem] {
        let promptId = turn.prompt?.id
        return turn.visibleItems.filter {
            if case .message(let message) = $0 { return message.id != promptId }
            return true
        }
    }

    @ViewBuilder
    private func iosDisclosureButton(_ turn: TranscriptTurn) -> some View {
        let isOpen = expandedTranscriptTurns.contains(turn.id)
        if turn.hasCollapsedContent {
            Button(action: ContinuumAnalytics.wrapButton("transcript_disclosure_toggle", {
                if isOpen {
                    expandedTranscriptTurns.remove(turn.id)
                } else {
                    expandedTranscriptTurns.insert(turn.id)
                }
            })) {
                iosDisclosureLabel(turn, icon: isOpen ? "chevron.down" : "chevron.right")
            }
            .buttonStyle(.plain)
        } else {
            iosDisclosureLabel(turn, icon: "clock")
        }
    }

    private func iosDisclosureLabel(_ turn: TranscriptTurn, icon: String) -> some View {
        Label(turn.summary.disclosureLabel, systemImage: icon)
            .font(TahoeFont.body(11.5, weight: .semibold))
            .foregroundStyle(t.fg3)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(t.glassTintHi, in: Capsule())
    }

    @ViewBuilder
    private func iosTurnChipStrip(_ turn: TranscriptTurn) -> some View {
        if !turn.outputArtifacts.isEmpty || !turn.editedFiles.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if !turn.outputArtifacts.isEmpty {
                    HStack(spacing: 7) {
                        ForEach(turn.outputArtifacts.prefix(4)) { artifact in
                            Button {
                                if artifact.kind == .markdown {
                                    openMarkdownDocument(artifact.path)
                                } else {
                                    UIPasteboard.general.string = artifact.path
                                }
                            } label: {
                                iosTranscriptChip(icon: iosArtifactIcon(artifact.kind), title: artifact.filename)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if !turn.editedFiles.isEmpty {
                    TranscriptEditedFileChipStripView(turn: turn)
                }
            }
            .padding(.leading, 34)
        }
    }

    private func iosTranscriptChip(icon: String, title: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10.5, weight: .semibold))
            Text(title)
                .font(TahoeFont.body(11.5, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(t.fg3)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(t.glassTintHi, in: Capsule())
    }

    private func iosArtifactIcon(_ kind: TranscriptArtifactKind) -> String {
        switch kind {
        case .markdown: return "doc.richtext"
        case .html: return "safari"
        case .image: return "photo"
        case .pdf: return "doc.text.magnifyingglass"
        case .document: return "doc.text"
        case .spreadsheet, .data: return "tablecells"
        case .presentation: return "rectangle.on.rectangle"
        case .media: return "play.rectangle"
        case .archive: return "archivebox"
        }
    }

    private func scrollChatPaneToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        chatPanePinned = true
        if animated {
            withAnimation(.easeInOut(duration: 0.32)) {
                proxy.scrollTo("ios-session-detail-bottom", anchor: .bottom)
            }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo("ios-session-detail-bottom", anchor: .bottom)
            }
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
        if isPlanApprovalMode { return "Approve or refine the plan above" }
        if isSessionRunning { return "Queue a follow-up while this turn runs…" }
        return "Send a follow-up…"
    }

    private var canSend: Bool {
        guard session != nil || data.isDemo else { return false }
        let hasText = !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasReadyAttachment = attachments.contains { $0.remotePath != nil }
        let anyUploading = attachments.contains(where: \.isUploading)
        if isPlanApprovalMode {
            return hasText && !anyUploading && session != nil && !data.isDemo
        }
        return (hasText || hasReadyAttachment) && !anyUploading
    }

    private var isSessionRunning: Bool {
        realAgentSession?.status == .running
    }

    private var isPlanApprovalMode: Bool {
        hasRealPlan && selectedTab == .chat
    }

    private var queueDrainKey: String {
        "\(sessionId.uuidString):\(realAgentSession?.status.rawValue ?? "missing"):\(queuedDrafts.count)"
    }

    private var sendButtonFill: LinearGradient {
        if isSessionRunning {
            return LinearGradient(colors: [t.fg3, t.fg4], startPoint: .top, endPoint: .bottom)
        }
        return LinearGradient(colors: [t.accent, t.accentDeepC], startPoint: .top, endPoint: .bottom)
    }

    private struct ComposerChipModel: Identifiable {
        let id: String
        let icon: String
        let text: String
        let isAccent: Bool
    }

    private var composerChips: [ComposerChipModel] {
        guard let realAgentSession else { return [] }
        var chips: [ComposerChipModel] = [
            ComposerChipModel(
                id: "provider",
                icon: "sparkles",
                text: realAgentSession.agent.tahoeProvider.displayName,
                isAccent: true
            )
        ]
        if let model = effectiveModelId(for: realAgentSession) {
            chips.append(ComposerChipModel(id: "model", icon: "code", text: model, isAccent: false))
        }
        chips.append(ComposerChipModel(id: "mode", icon: "branch", text: realAgentSession.mode.rawValue.capitalized, isAccent: false))
        chips.append(ComposerChipModel(id: "effort", icon: "gauge", text: effortText(for: realAgentSession), isAccent: false))
        if !chatStore.snapshot.sourceEntries.isEmpty {
            chips.append(ComposerChipModel(id: "sources", icon: "link", text: "\(chatStore.snapshot.sourceEntries.count) sources", isAccent: false))
        }
        if queuedDrafts.count > 0 {
            chips.append(ComposerChipModel(id: "queue", icon: "tray", text: "\(queuedDrafts.count) queued", isAccent: true))
        }
        if !attachments.isEmpty {
            chips.append(ComposerChipModel(id: "attachments", icon: "paperclip", text: "\(attachments.count) attached", isAccent: false))
        }
        return chips
    }

    private func effectiveModelId(for session: AgentSession) -> String? {
        let explicit = [
            session.runtimeBinding?.providerModelId,
            session.model
        ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        if let explicit { return explicit }
        return ComposerStore.ChipDefaults.for(agent: session.agent, catalog: agentClient.modelCatalog).modelId
    }

    private func effortText(for session: AgentSession) -> String {
        if let effort = session.effort {
            return effort.rawValue.uppercased()
        }
        if let modelId = effectiveModelId(for: session),
           let entry = agentClient.modelCatalog.entry(forId: modelId),
           !entry.supportsEffort {
            return "DEFAULT"
        }
        return ComposerStore.ChipDefaults.for(agent: session.agent, catalog: agentClient.modelCatalog).effort?.rawValue.uppercased() ?? "DEFAULT"
    }

    private func composerChip(_ chip: ComposerChipModel) -> some View {
        HStack(spacing: 5) {
            TahoeIcon(chip.icon, size: 10.5)
            Text(chip.text)
                .lineLimit(1)
        }
        .font(TahoeFont.body(10.5, weight: .bold))
        .foregroundStyle(chip.isAccent ? t.accent : t.fg3)
        .padding(.horizontal, 8)
        .frame(height: 23)
        .background(chip.isAccent ? t.accentAlpha(0.12) : t.hair2, in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .stroke(chip.isAccent ? t.accentAlpha(0.35) : t.hairline, lineWidth: 0.5)
        }
    }

    private var attachButton: some View {
        PhotosPicker(
            selection: $photoPickerItems,
            maxSelectionCount: 4,
            matching: .images
        ) {
            TahoeIcon("paperclip", size: 15, weight: .bold)
                .foregroundStyle(t.fg3)
                .frame(width: 34, height: 34)
                .background(t.hair2, in: Circle())
        }
        .photosPickerStyle(.presentation)
        .disabled(isPlanApprovalMode || session == nil || data.isDemo)
        .opacity((isPlanApprovalMode || session == nil || data.isDemo) ? 0.45 : 1)
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    attachmentChip(attachment)
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxHeight: 64)
    }

    private func attachmentChip(_ attachment: ComposerAttachment) -> some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                #if canImport(UIKit)
                if let image = UIImage(data: attachment.thumbnailData) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 54, height: 54)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                } else {
                    fallbackAttachmentThumbnail
                }
                #else
                fallbackAttachmentThumbnail
                #endif
                if attachment.isUploading {
                    Color.black.opacity(0.42)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .tint(.white)
                } else if attachment.uploadError != nil {
                    Color.red.opacity(0.54)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    TahoeIcon("x", size: 14, weight: .bold)
                        .foregroundStyle(.white)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(t.hairline, lineWidth: 0.5)
            }
            Button {
                removeAttachment(attachment.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white, Color.black.opacity(0.62))
            }
            .buttonStyle(.plain)
            .offset(x: 6, y: -6)
        }
        .help(attachment.uploadError ?? attachment.filename)
    }

    private var fallbackAttachmentThumbnail: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(t.hair2)
            .frame(width: 54, height: 54)
            .overlay {
                TahoeIcon("doc", size: 18)
                    .foregroundStyle(t.fg3)
            }
    }

    private var queuedDraftsPanel: some View {
        TahoeGlass(radius: 6, tone: .chip) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    TahoeIcon("tray", size: 12)
                        .foregroundStyle(t.fg3)
                    Text("Queued follow-ups")
                        .font(TahoeFont.body(11.5, weight: .bold))
                        .foregroundStyle(t.fg2)
                    Text("\(queuedDrafts.count)")
                        .font(TahoeFont.mono(10.5, weight: .bold))
                        .foregroundStyle(t.fg4)
                    Spacer()
                    Button("Clear", action: ContinuumAnalytics.wrapButton(
                            "clear",
                            {
                        queuedDrafts = []
                        persistQueuedDrafts()
                    
                            }
                        ))
                    .font(TahoeFont.body(10.5, weight: .semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(t.fg3)
                }
                ForEach(queuedDrafts) { draft in
                    queuedDraftRow(draft)
                }
            }
            .padding(12)
        }
    }

    private func queuedDraftRow(_ draft: IOSQueuedCodeDraft) -> some View {
        HStack(alignment: .top, spacing: 8) {
            TextField(
                "Queued prompt",
                text: Binding(
                    get: { draft.text },
                    set: { updateQueuedDraft(id: draft.id, text: $0) }
                ),
                axis: .vertical
            )
            .font(TahoeFont.body(12))
            .foregroundStyle(t.fg)
            .lineLimit(1...3)
            .textFieldStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(t.hair2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            Button {
                Task { await dispatchQueuedDraft(draft, manual: true) }
            } label: {
                TahoeIcon("arrowU", size: 12, weight: .bold)
                    .foregroundStyle(isSessionRunning ? t.fg4 : t.accent)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .disabled(isSessionRunning || isDispatchingQueuedDraft)

            Button(role: .destructive, action: ContinuumAnalytics.wrapButton(
                    "remove_queued_draft",
                    {
                removeQueuedDraft(id: draft.id)
            
                    }
                )) {
                TahoeIcon("x", size: 11, weight: .bold)
                    .foregroundStyle(.red.opacity(0.8))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Actions

    @MainActor
    private func sendComposer() async {
        let trimmed = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        let composed = composedPrompt(text: trimmed)
        guard !composed.isEmpty, session != nil else { return }
        // Demo bindings short-circuit — clear the text but don't hit the
        // wire (the demo session id wouldn't resolve on the daemon side).
        if data.isDemo {
            composerText = ""
            attachments.removeAll()
            return
        }
        if isSessionRunning {
            queueDraft(text: composed)
            composerText = ""
            attachments.removeAll()
            return
        }
        // v0.26 follow-up: route through outbox so retries dedup via the
        // wire-v16 idempotency contract, offline sends queue + retry
        // with exp backoff, and failures surface in the per-session
        // outbox badge instead of getting silently swallowed. Clear
        // composer immediately — the outbox owns delivery from here
        // on, and a stuck delivery is now visible in the queue UI
        // rather than holding the composer hostage.
        outbox.enqueueSend(sessionId: sessionId, text: composed, asFollowUp: true)
        composerText = ""
        attachments.removeAll()
    }

    @MainActor
    private func performTurnRetry(promptBody: String) async {
        guard session != nil, !data.isDemo else { return }
        guard chatStore.snapshot.currentTurnState != .streaming else { return }
        guard !isRetrying else { return }
        let trimmed = promptBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isRetrying = true
        defer { isRetrying = false }
        if isSessionRunning {
            queueDraft(text: trimmed)
            return
        }
        outbox.enqueueSend(sessionId: sessionId, text: trimmed, asFollowUp: true)
    }

    @MainActor
    private func performTurnRetryInNewChat(promptBody: String) async {
        guard let session = realAgentSession,
              let key = WorkspaceKey.of(session),
              !data.isDemo
        else { return }
        let trimmed = promptBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let goal = String(trimmed.prefix(80))
        guard let newSession = await agentClient.createSession(
            NewSessionRequest(
                repoKey: key.repoKey,
                agent: session.agent,
                model: session.model,
                planMode: session.status == .planning,
                goal: goal.isEmpty ? nil : goal,
                useWorktree: session.mode == .worktree,
                effort: session.effort,
                providerInstanceId: session.providerInstanceId,
                existingWorkspacePath: key.workspacePath,
                customProviderId: session.customProviderId
            )
        ) else {
            lastError = agentClient.lastError ?? "Couldn't start a new chat."
            return
        }
        onOpenSession(newSession.id)
        outbox.enqueueSend(sessionId: newSession.id, text: trimmed, asFollowUp: false)
    }

    private func composedPrompt(text trimmed: String) -> String {
        let uploadedPaths = attachments.compactMap(\.remotePath)
        let attachmentPrefix = uploadedPaths.map { "@\($0)" }.joined(separator: "\n")
        if !attachmentPrefix.isEmpty && !trimmed.isEmpty {
            return attachmentPrefix + "\n\n" + trimmed
        } else if !attachmentPrefix.isEmpty {
            return attachmentPrefix
        }
        return trimmed
    }

    @MainActor
    private func removeAttachment(_ id: UUID) {
        attachments.removeAll { $0.id == id }
    }

    @MainActor
    private func ingestPhotoPickerItems(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        photoPickerItems = []
        guard let realAgentSession else { return }
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let ext = Self.inferExtension(from: data) ?? "jpg"
            let attachmentId = UUID()
            let thumbData = Self.thumbnail(from: data, max: 256) ?? data
            attachments.append(ComposerAttachment(
                id: attachmentId,
                filename: "attachment.\(ext)",
                thumbnailData: thumbData,
                remotePath: nil,
                uploadError: nil,
                isUploading: true
            ))
            Task {
                let remote = await agentClient.uploadAttachment(sessionId: realAgentSession.id, ext: ext, data: data)
                await MainActor.run {
                    guard let index = attachments.firstIndex(where: { $0.id == attachmentId }) else { return }
                    if let remote {
                        attachments[index].remotePath = remote
                        attachments[index].isUploading = false
                    } else {
                        attachments[index].isUploading = false
                        attachments[index].uploadError = agentClient.lastError ?? "Upload failed"
                    }
                }
            }
        }
    }

    private static func inferExtension(from data: Data) -> String? {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if bytes.starts(with: [0xFF, 0xD8]) { return "jpg" }
        if bytes.starts(with: [0x47, 0x49, 0x46]) { return "gif" }
        if bytes.count >= 12,
           bytes[4] == 0x66, bytes[5] == 0x74, bytes[6] == 0x79, bytes[7] == 0x70 {
            return "heic"
        }
        return nil
    }

    private static func thumbnail(from data: Data, max: CGFloat) -> Data? {
        #if canImport(UIKit)
        guard let image = UIImage(data: data) else { return nil }
        let scale = min(max / image.size.width, max / image.size.height, 1)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        let rendered = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return rendered.jpegData(compressionQuality: 0.74)
        #else
        return nil
        #endif
    }

    @MainActor
    private func queueDraft(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        queuedDrafts.append(IOSQueuedCodeDraft(sessionId: sessionId, text: trimmed))
        persistQueuedDrafts()
    }

    @MainActor
    private func updateQueuedDraft(id: UUID, text: String) {
        guard let index = queuedDrafts.firstIndex(where: { $0.id == id }) else { return }
        queuedDrafts[index].text = text
        persistQueuedDrafts()
    }

    @MainActor
    private func removeQueuedDraft(id: UUID) {
        queuedDrafts.removeAll { $0.id == id }
        persistQueuedDrafts()
    }

    @MainActor
    private func drainQueuedDraftsIfPossible() async {
        guard !isSessionRunning,
              !isDispatchingQueuedDraft,
              !dispatchedQueuedTurnForCurrentIdle,
              let draft = queuedDrafts.sorted(by: { $0.createdAt < $1.createdAt }).first
        else { return }
        dispatchedQueuedTurnForCurrentIdle = true
        await dispatchQueuedDraft(draft, manual: false)
    }

    @MainActor
    private func dispatchQueuedDraft(_ draft: IOSQueuedCodeDraft, manual: Bool) async {
        guard !isSessionRunning, !isDispatchingQueuedDraft else { return }
        let trimmed = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            removeQueuedDraft(id: draft.id)
            return
        }
        isDispatchingQueuedDraft = true
        defer { isDispatchingQueuedDraft = false }
        outbox.enqueueSend(sessionId: sessionId, text: trimmed, asFollowUp: true)
        removeQueuedDraft(id: draft.id)
    }

    private static func queuedDraftsKey(sessionId: UUID) -> String {
        "clawdmeter.ios.session.\(sessionId.uuidString).queuedDrafts"
    }

    private static func loadQueuedDrafts(sessionId: UUID) -> [IOSQueuedCodeDraft] {
        guard let data = UserDefaults.standard.data(forKey: queuedDraftsKey(sessionId: sessionId)),
              let decoded = try? JSONDecoder().decode([IOSQueuedCodeDraft].self, from: data)
        else { return [] }
        return decoded.filter { $0.sessionId == sessionId }
            .sorted { $0.createdAt < $1.createdAt }
    }

    private func persistQueuedDrafts() {
        guard let data = try? JSONEncoder().encode(queuedDrafts) else { return }
        UserDefaults.standard.set(data, forKey: Self.queuedDraftsKey(sessionId: sessionId))
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
        guard !approving, session != nil else { return }
        guard !data.isDemo else { return }  // demo plan, no real id to approve
        approving = true
        outbox.enqueueApprovePlan(sessionId: sessionId)
        // Hold the guard for ~2s — the daemon respawn + WS push that
        // flips `hasRealPlan` typically lands in <1s on a tailnet, so
        // the button's own `canApprove` takes over before this timer
        // expires. Re-arming briefly on slow networks is fine; the
        // outbox itself owns idempotent delivery from here. NOT using
        // `defer` because that clears the flag in the same MainActor
        // turn, leaving the network round-trip window unguarded.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            approving = false
        }
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
    var sessionId: UUID
    var provider: TahoeProvider
    @ObservedObject var presentationStore: SessionPresentationStore
    var onOpenMarkdownDocument: (String) -> Void
    var modelFailureRetryPrompt: String? = nil
    var onRetryFailedTurn: ((String) -> Void)? = nil
    var onRetryFailedTurnInNewChat: ((String) -> Void)? = nil

    var body: some View {
        switch item {
        case .message(let message):
            messageRow(message)
        case .toolRun(_, let pairs):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(markdownArtifacts(in: pairs)) { artifact in
                    markdownArtifactButton(path: artifact.path)
                }
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
        Group {
            switch message.kind {
            case .userText:
                HStack {
                    Spacer()
                    TahoeGlass(radius: 8, tone: .raised) {
                        Text(message.body)
                            .font(TahoeFont.body(13))
                            .foregroundStyle(t.fg)
                            .padding(.horizontal, 15).padding(.vertical, 11)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: 320, alignment: .trailing)
                }
            case .assistantText:
                if message.isError {
                    errorAssistantRow(message)
                } else {
                    HStack(alignment: .top, spacing: 9) {
                        TahoeProviderGlyph(provider: provider, size: 24)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(message.body)
                                .font(TahoeFont.body(14))
                                .foregroundStyle(t.fg)
                                .fixedSize(horizontal: false, vertical: true)
                            ForEach(markdownArtifacts(in: message)) { artifact in
                                markdownArtifactButton(path: artifact.path)
                            }
                        }
                        Spacer()
                    }
                }
            case .toolCall, .toolResult:
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        ToolIconView(toolName: message.title, size: 11, isError: message.isError)
                        if message.kind == .toolCall,
                           let path = TechStackIconCatalog.filePathHint(toolTitle: message.title, body: message.body) {
                            TechStackIconView(path: path, size: 12)
                        } else if message.kind == .toolResult {
                            TahoeIcon("check", size: 11).foregroundStyle(t.fg3)
                        }
                        Text(message.title)
                            .font(TahoeFont.body(11.5, weight: .semibold))
                            .foregroundStyle(t.fg2)
                        Text(message.body)
                            .font(TahoeFont.mono(11))
                            .foregroundStyle(message.isError ? .red : t.fg3)
                            .lineLimit(2)
                        Spacer()
                    }
                    ForEach(markdownArtifacts(in: message)) { artifact in
                        markdownArtifactButton(path: artifact.path)
                    }
                }
                .padding(.horizontal, 4).padding(.vertical, 4)
            case .meta:
                if message.title == "Thinking" {
                    ThinkingActionRow(summary: message.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(message.body)
                        .font(TahoeFont.body(11.5))
                        .foregroundStyle(t.fg3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .contextMenu {
            Button("Copy Message", systemImage: "doc.on.doc", action: ContinuumAnalytics.wrapButton("copy_message", { UIPasteboard.general.string = message.body }))
            Button("Copy Message ID", systemImage: "number", action: ContinuumAnalytics.wrapButton("copy_message_id", { UIPasteboard.general.string = message.id }))
            Button(
                presentationStore.snapshot.messageBookmarks[sessionId]?.contains(message.id) == true ? "Remove Bookmark" : "Bookmark",
                systemImage: "bookmark",
                action: ContinuumAnalytics.wrapButton("toggle_message_bookmark", { try? presentationStore.toggleMessageBookmark(sessionId: sessionId, messageId: message.id) })
            )
            Button("Copy as Quote", systemImage: "quote.bubble", action: ContinuumAnalytics.wrapButton("copy_message_quote", {
                UIPasteboard.general.string = message.body
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .map { "> \($0)" }
                    .joined(separator: "\n")
            }))
        }
    }

    private func errorAssistantRow(_ message: ChatMessage) -> some View {
        HStack(alignment: .top, spacing: 9) {
            TahoeProviderGlyph(provider: provider, size: 24)
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(SessionsV2Theme.danger)
                        Text("Model failed")
                            .font(TahoeFont.body(11, weight: .semibold))
                            .foregroundStyle(SessionsV2Theme.danger)
                    }
                    Text(message.body)
                        .font(TahoeFont.body(14))
                        .foregroundStyle(t.fg)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(SessionsV2Theme.danger.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(SessionsV2Theme.danger.opacity(0.55), lineWidth: 1.25)
                )
                .accessibilityLabel("Model failed: \(message.body)")

                if let retryPrompt = modelFailureRetryPrompt {
                    modelFailureActionRow(retryPrompt: retryPrompt)
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func modelFailureActionRow(retryPrompt: String) -> some View {
        HStack(spacing: 10) {
            ForEach(Array(ModelFailureRecovery.actionDescriptors().enumerated()), id: \.offset) { _, descriptor in
                switch descriptor.kind {
                case .retry:
                    Button(descriptor.visibleTitle, action: ContinuumAnalytics.wrapButton("retry_failed_turn", { onRetryFailedTurn?(retryPrompt) }))
                    .buttonStyle(.plain)
                    .font(TahoeFont.body(11, weight: .semibold))
                    .foregroundStyle(t.accent)
                    .accessibilityIdentifier(descriptor.accessibilityIdentifier)
                case .retryInNewChat:
                    Button(descriptor.visibleTitle, action: ContinuumAnalytics.wrapButton("retry_failed_turn_new_chat", { onRetryFailedTurnInNewChat?(retryPrompt) }))
                    .buttonStyle(.plain)
                    .font(TahoeFont.body(11, weight: .semibold))
                    .foregroundStyle(t.accent)
                    .accessibilityIdentifier(descriptor.accessibilityIdentifier)
                }
            }
        }
    }

    private func markdownArtifacts(in pairs: [ToolPair]) -> [GeneratedArtifact] {
        var seen = Set<String>()
        var out: [GeneratedArtifact] = []
        for artifact in pairs.flatMap({ $0.call.generatedArtifacts }) where artifact.kind == .markdownDocument {
            guard !seen.contains(artifact.path) else { continue }
            seen.insert(artifact.path)
            out.append(artifact)
        }
        return out
    }

    private func markdownArtifacts(in message: ChatMessage) -> [GeneratedArtifact] {
        var artifacts = message.generatedArtifacts.filter { $0.kind == .markdownDocument }
        if artifacts.isEmpty {
            artifacts = GeneratedArtifactDetector.artifactsFromDisplay(
                title: message.title,
                body: message.body,
                detail: message.detail
            )
        }
        if artifacts.isEmpty {
            artifacts = GeneratedArtifactDetector.artifactsFromDisplay(
                title: "write_file",
                body: message.body,
                detail: message.detail
            )
        }
        var seen = Set<String>()
        var out: [GeneratedArtifact] = []
        for artifact in artifacts {
            guard !seen.contains(artifact.path) else { continue }
            seen.insert(artifact.path)
            out.append(artifact)
        }
        return out
    }

    private func markdownArtifactButton(path: String) -> some View {
        Button(action: ContinuumAnalytics.wrapButton("open_markdown_artifact", { onOpenMarkdownDocument(path) })) {
            HStack(spacing: 8) {
                Image(systemName: "doc.richtext")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(t.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text((path as NSString).lastPathComponent.isEmpty ? path : (path as NSString).lastPathComponent)
                        .font(TahoeFont.body(12, weight: .semibold))
                        .foregroundStyle(t.fg)
                        .lineLimit(1)
                    Text("Open in Code tab")
                        .font(TahoeFont.body(10.5, weight: .medium))
                        .foregroundStyle(t.fg3)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                TahoeIcon("chevR", size: 10)
                    .foregroundStyle(t.fg4)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(t.glassTintHi, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(t.hairline, lineWidth: 0.5)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Open \(path) in Code tab"))
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
                TahoeGlass(radius: 8, tone: .raised) {
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

#if DEBUG && canImport(UIKit)
@MainActor
private final class IOSScrollPerformanceProbe: NSObject, ObservableObject {
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private var startedAt: CFTimeInterval = 0
    private var intervalsMs: [Double] = []
    private var label: String = ""
    private var itemCount: Int = 0

    private var enabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--ios-code-demo-scroll-probe")
    }

    private var durationSeconds: Double {
        let prefix = "--ios-code-demo-scroll-probe-seconds="
        for argument in ProcessInfo.processInfo.arguments where argument.hasPrefix(prefix) {
            let raw = String(argument.dropFirst(prefix.count))
            if let value = Double(raw), value > 0 {
                return min(value, 60)
            }
        }
        return 12
    }

    private var warmupSeconds: Double {
        let prefix = "--ios-code-demo-scroll-probe-warmup="
        for argument in ProcessInfo.processInfo.arguments where argument.hasPrefix(prefix) {
            let raw = String(argument.dropFirst(prefix.count))
            if let value = Double(raw), value >= 0 {
                return min(value, 10)
            }
        }
        return 1
    }

    func start(label: String, itemCount: Int) {
        guard enabled, displayLink == nil else { return }
        self.label = label
        self.itemCount = itemCount
        intervalsMs = []
        lastTimestamp = nil
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        startedAt = CACurrentMediaTime()
        displayLink = link
        link.add(to: .main, forMode: .common)
    }

    func stopAndLog(reason: String) {
        guard let link = displayLink else { return }
        link.invalidate()
        displayLink = nil
        guard !intervalsMs.isEmpty else {
            print("IOS_SCROLL_PROBE label=\(label) reason=\(reason) items=\(itemCount) samples=0")
            return
        }
        let sorted = intervalsMs.sorted()
        let p50 = percentile(sorted, fraction: 0.50)
        let p95 = percentile(sorted, fraction: 0.95)
        let p99 = percentile(sorted, fraction: 0.99)
        let maxInterval = sorted.last ?? 0
        let over20 = intervalsMs.filter { $0 > 20 }.count
        let over33 = intervalsMs.filter { $0 > 33.4 }.count
        let average = intervalsMs.reduce(0, +) / Double(intervalsMs.count)
        let fps = average > 0 ? 1_000 / average : 0
        print(String(
            format: "IOS_SCROLL_PROBE label=%@ reason=%@ items=%d samples=%d p50=%.2fms p95=%.2fms p99=%.2fms max=%.2fms over20=%d over33=%d avgFps=%.1f",
            label,
            reason,
            itemCount,
            intervalsMs.count,
            p50,
            p95,
            p99,
            maxInterval,
            over20,
            over33,
            fps
        ))
    }

    @objc private func tick(_ link: CADisplayLink) {
        let elapsed = link.timestamp - startedAt
        if let lastTimestamp, elapsed >= warmupSeconds {
            intervalsMs.append((link.timestamp - lastTimestamp) * 1_000)
        }
        lastTimestamp = link.timestamp
        if elapsed >= durationSeconds {
            stopAndLog(reason: "duration")
        }
    }

    private func percentile(_ sorted: [Double], fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let clamped = min(max(fraction, 0), 1)
        let index = Int((Double(sorted.count - 1) * clamped).rounded())
        return sorted[index]
    }

    deinit {
        displayLink?.invalidate()
    }
}
#endif

private struct IOSPlanHaloMini: View {
    @Environment(\.tahoe) private var t
    /// Plan steps to render. Pre-parsed by the parent — empty means hide.
    var steps: [String]
    /// Whether Approve & run is enabled. False when the session is not
    /// actually in plan-mode (the daemon would reject a no-op approval).
    var canApprove: Bool
    var onRefine: () -> Void
    var onApprove: () -> Void

    private var estimatedCostLabel: String {
        switch steps.count {
        case 0...2: return "~$0.08"
        case 3: return "~$0.12"
        case 4: return "~$0.15"
        default: return "~$0.18"
        }
    }

    var body: some View {
        if steps.isEmpty {
            EmptyView()
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(RadialGradient(
                        colors: [.clear, .clear],
                        center: UnitPoint(x: 0.5, y: 0.3), startRadius: 0, endRadius: 400))
                    .blur(radius: 6).padding(-20).allowsHitTesting(false)

                TahoeGlass(radius: 8, tone: .raised) {
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
                                    .font(TahoeFont.body(10.5, weight: .bold))
                                    .foregroundStyle(t.fg)
                                Text("\(steps.count) step\(steps.count == 1 ? "" : "s") · \(estimatedCostLabel)")
                                    .font(TahoeFont.body(11.5, weight: .semibold))
                                    .foregroundStyle(t.fg3)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)

                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(Array(steps.prefix(3).enumerated()), id: \.offset) { i, step in
                                HStack(alignment: .top, spacing: 9) {
                                    ZStack {
                                        // DESIGN.md Plan Card: step 1 badge uses accent@18% + accent text.
                                        RoundedRectangle(cornerRadius: 5, style: .continuous).fill(i == 0 ? t.accentAlpha(0.18) : t.hair2)
                                        Text("\(i+1)").font(TahoeFont.mono(10, weight: .bold)).foregroundStyle(i == 0 ? t.accent : t.fg2)
                                    }
                                    .frame(width: 18, height: 18)
                                    Text(step)
                                        .font(TahoeFont.body(12))
                                        .foregroundStyle(t.fg)
                                        .lineLimit(2)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            if steps.count > 3 {
                                Text("+ \(steps.count - 3) more step\(steps.count - 3 == 1 ? "" : "s")...")
                                    .font(TahoeFont.body(11))
                                    .foregroundStyle(t.fg3)
                                    .padding(.leading, 27)
                            }
                        }
                        .padding(.horizontal, 16).padding(.top, 2).padding(.bottom, 11)

                        TahoeHair()

                        HStack(spacing: 8) {
                            TahoeGhostButton(size: .m, action: onRefine) { Text("Refine") }
                                .frame(maxWidth: .infinity)
                            TahoeAccentButton(size: .m, action: onApprove) { Text("Approve & run") }
                                .frame(maxWidth: .infinity)
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

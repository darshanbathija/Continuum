import SwiftUI
import AppKit
import ClawdmeterShared

/// Mac menu bar app entry point.
///
/// Per codex's diagnosis: `MenuBarExtra` label `.task` modifiers on macOS Tahoe
/// are unreliable for starting app-owned work. Both AppModels are owned by an
/// app-level `AppRuntime` (`@StateObject`), which starts them in its init and
/// forwards their `objectWillChange` so MenuBarExtra scenes invalidate reliably.
// MARK: - v0.22.9: In-app tab navigation notifications

extension Notification.Name {
    /// Posted from menu items (Cmd+1..Cmd+4) or the Settings menu (Cmd+,)
    /// to switch the dashboard window's active tab. MacRootView observes
    /// this and updates its `@State tab`. Carries `userInfo["tab"]` ==
    /// "chat"|"usage"|"code"|"settings".
    static let clawdmeterSwitchTab = Notification.Name("clawdmeter.switchTab")
    /// v0.22.19: ⌘K from anywhere flips to the Code tab and focuses the
    /// sidebar Search field. MacRootView listens — it flips the tab if
    /// needed and re-emits to the Sidebar via FocusState binding.
    static let clawdmeterFocusCodeSearch = Notification.Name("clawdmeter.focusCodeSearch")
    static let clawdmeterOpenGlobalPalette = Notification.Name("clawdmeter.openGlobalPalette")
    /// Carries `userInfo["section"]` for settings deep links such as
    /// "updates" and "devices".
    static let clawdmeterOpenSettingsSection = Notification.Name("clawdmeter.openSettingsSection")
    static let clawdmeterOpenShortcutSheet = Notification.Name("clawdmeter.openShortcutSheet")
    static let clawdmeterOpenFilePicker = Notification.Name("clawdmeter.openFilePicker")
    static let clawdmeterExportSession = Notification.Name("clawdmeter.exportSession")
    static let clawdmeterShowTransientToast = Notification.Name("clawdmeter.showTransientToast")
    static let clawdmeterInsertComposerText = Notification.Name("clawdmeter.insertComposerText")
    /// App-level workspace tab commands. Kept as notifications so the
    /// Code workspace can resolve the currently-open session and no app
    /// command closure needs to reach into `SessionsModel` directly.
    static let clawdmeterOpenWorkspaceChatTab = Notification.Name("clawdmeter.openWorkspaceChatTab")
    static let clawdmeterOpenWorkspaceTerminalTab = Notification.Name("clawdmeter.openWorkspaceTerminalTab")
    /// Posted from the titlebar's "Continue Plan" chip to open the
    /// spawn queue modal in MacRootView.
    static let clawdmeterShowPlanQueue = Notification.Name("clawdmeter.showPlanQueue")
}

@main
struct ClawdmeterMacApp: App {
    @StateObject private var runtime = AppRuntime()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// Shared helper for the `View` command menu — posts a `switchTab`
    /// notification that MacRootView listens for. `static` so the menu
    /// item closures don't capture self (avoids strong-ref churn at
    /// each keyboard-shortcut firing).
    fileprivate static func postSwitchTab(_ name: String) {
        NotificationCenter.default.post(
            name: .clawdmeterSwitchTab,
            object: nil,
            userInfo: ["tab": name]
        )
    }

    init() {
        // Hand the AppDelegate a reference to the runtime so its
        // applicationDidFinishLaunching has the models in hand. The delegate
        // creates the menu bar status items based on user prefs.
        // (Set after `runtime` is initialized — @StateObject's wrapped value
        // is constructed lazily on first access, so we read it once here.)
    }

    var body: some Scene {
        // Main window — appears when launched from /Applications, Spotlight,
        // or the Dock. Both providers side-by-side. The menu bar items are
        // created/destroyed by `AppDelegate` based on the per-provider
        // "show in menu bar" toggles in the dashboard.
        //
        // No more `MenuBarExtra` — the dashboard's toggles need to hide the
        // status items conditionally, which `MenuBarExtra(isInserted:)`
        // can't do without triggering Tahoe's KVO loop. `NSStatusItem`
        // (managed by AppDelegate) supports `.isVisible` natively.
        Window("Continuum", id: "dashboard") {
            // Tahoe 26 redesign: the new MacRootView owns the four
            // titlebar tabs (Chat / Usage / Code / Settings) and the
            // global TahoeThemeStore. The runtime is threaded in so the
            // Usage tab + menu-bar popover render live per-provider data
            // via the `tahoeLive` adapter (see MacTahoeAdapter.swift).
            MacRootView(runtime: runtime)
                .background(DashboardOpener())   // bridges AppDelegate → openWindow
                .onAppear {
                    appDelegate.configure(runtime: runtime)
                    NotificationCenter.default.post(
                        name: UserDefaults.didChangeNotification, object: nil
                    )
                    NSApp.setActivationPolicy(.regular)
                }
        }
        // Sized to comfortably show the three-column Chat compare layout
        // (sidebar 248 + 3×~340 columns + gaps) at first open.
        .defaultSize(width: 1320, height: 920)
        .windowResizability(.contentMinSize)
        // v0.22.9: app + view-level command groups. Cmd+, swaps the
        // dashboard's active tab to Settings (instead of opening the
        // separate Settings window scene we deleted). Cmd+1..Cmd+4
        // jump between the dashboard tabs. The previous hidden
        // Menu items stay discoverable here; keyboard dispatch is owned by
        // MacRootView so client-local shortcut overrides can replace defaults.
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    NotificationCenter.default.post(
                        name: .clawdmeterSwitchTab,
                        object: nil,
                        userInfo: ["tab": "settings"]
                    )
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    runtime.updateCoordinator.refreshUpdateStatus()
                    NotificationCenter.default.post(
                        name: .clawdmeterOpenSettingsSection,
                        object: nil,
                        userInfo: ["section": "updates"]
                    )
                }
            }
            CommandGroup(after: .toolbar) {
                Button("Chat") { Self.postSwitchTab("chat") }
                Button("Usage") { Self.postSwitchTab("usage") }
                Button("Code") { Self.postSwitchTab("code") }
                Button("Settings") { Self.postSwitchTab("settings") }
                Divider()
                Button("Command Palette") {
                    NotificationCenter.default.post(name: .clawdmeterOpenGlobalPalette, object: nil)
                }
                Button("Keyboard Shortcuts") {
                    NotificationCenter.default.post(name: .clawdmeterOpenShortcutSheet, object: nil)
                }
                Button("Open File…") {
                    NotificationCenter.default.post(name: .clawdmeterOpenFilePicker, object: nil)
                }
                Button("Export Open Session…") {
                    NotificationCenter.default.post(name: .clawdmeterExportSession, object: nil)
                }
                Button("Search Code") {
                    NotificationCenter.default.post(
                        name: .clawdmeterSwitchTab,
                        object: nil,
                        userInfo: ["tab": "code"]
                    )
                    NotificationCenter.default.post(
                        name: .clawdmeterFocusCodeSearch,
                        object: nil
                    )
                }
                Button("New Workspace Chat Tab") {
                    Self.postSwitchTab("code")
                    NotificationCenter.default.post(name: .clawdmeterOpenWorkspaceChatTab, object: nil)
                }
                .keyboardShortcut("t", modifiers: [.command])
                Button("New Workspace Terminal") {
                    Self.postSwitchTab("code")
                    NotificationCenter.default.post(name: .clawdmeterOpenWorkspaceTerminalTab, object: nil)
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                Button("Find in Transcript") {
                    NotificationCenter.default.post(name: .transcriptFind, object: nil)
                }
                Button("Next Transcript Match") {
                    NotificationCenter.default.post(name: .transcriptNextMatch, object: nil)
                }
                Button("Previous Transcript Match") {
                    NotificationCenter.default.post(name: .transcriptPreviousMatch, object: nil)
                }
                Button("Next Attention Session") {
                    NotificationCenter.default.post(name: .sessionNextAttention, object: nil)
                }
                Button("Toggle Review Pane") {
                    NotificationCenter.default.post(name: .toggleCodeReviewPane, object: nil)
                }
            }
        }
        // v0.22.6 fix: hide the native macOS titlebar so the Tahoe
        // titlebar (MacRootView's MacTitlebar chip with the tabs +
        // status chips) IS the top of the window instead of stacking
        // beneath it. The macOS traffic-light controls remain
        // functional — they overlay the top-left corner — and
        // `MacTitlebar` reserves left padding so they don't collide
        // with the tab text.
        .windowStyle(.hiddenTitleBar)
        // v0.22.7: drop `.windowToolbarStyle(.unifiedCompact(...))` —
        // even with no `.toolbar { … }` modifier present, that style
        // reserves a thin toolbar band at the top of the window which
        // pushed the Tahoe titlebar chip down by ~28pt and left a
        // visible dark gap above it. `.hiddenTitleBar` alone is what
        // we want: SwiftUI content extends to the very top of the
        // window and the macOS traffic lights overlay the top-left
        // at their canonical position.

        // G14: pop-out window for a single session. Accepts a UUID via the
        // `openWindow(value:)` environment action. The window's title and
        // content reflect the chosen session; closing it doesn't affect the
        // main dashboard.
        WindowGroup("Session", id: "session-detail", for: UUID.self) { $sessionId in
            if let sessionId,
               let session = runtime.agentSessionRegistry.sessions.first(where: { $0.id == sessionId }) {
                PoppedOutSessionView(session: session, model: runtime.sessionsModel)
            } else {
                ContentUnavailableView(
                    "Session not found",
                    systemImage: "questionmark.circle",
                    description: Text("This session may have been closed.")
                )
            }
        }
        .defaultSize(width: 720, height: 720)

        Window("Status HUD", id: "status-hud") {
            StatusHUDView(runtime: runtime)
                .onAppear { appDelegate.configure(runtime: runtime) }
        }
        .defaultSize(width: 420, height: 360)

        // v0.22.9: dropped the legacy `Settings { TabView { ... } }`
        // scene that opened a separate (broken-looking, light/dark-
        // inconsistent) modal window on Cmd+,. All settings now live
        // inside the dashboard's Settings tab — see MacSettingsView.
        // Cmd+, is wired below via `.commands { CommandGroup(replacing:
        // .appSettings) }` so it switches the dashboard tab instead of
        // opening a new window.
    }
}

// MARK: - Pop-out session window

/// G14 detachable session view. Shows just the chat thread + composer for
/// the chosen session; no sidebar, no review pane. The host window picks
/// up the `.floating` level when the user toggles "Stay on top" in the
/// Window menu (handled by AppDelegate).
struct PoppedOutSessionView: View {
    let session: AgentSession
    @ObservedObject var model: SessionsModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let store = model.chatStore(for: session) {
                PoppedChatThread(store: store, session: session, model: model)
            } else {
                ContentUnavailableView {
                    Label("No JSONL yet", systemImage: "ellipsis.bubble")
                } description: {
                    Text("Waiting for the agent to write its first message…")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(bg)
        .frame(minWidth: 480, minHeight: 360)
        // Register this session as protected from LRU eviction while the
        // pop-out window is on screen. Without this, navigating through
        // three other sessions in the main workspace would evict and
        // `stop()` this window's chat store underneath it (Codex M1).
        .onAppear { model.protectSession(session.id) }
        .onDisappear { model.unprotectSession(session.id) }
    }

    private var header: some View {
        HStack {
            Circle().fill(.green).frame(width: 8, height: 8)
            Text(session.goal ?? session.repoDisplayName)
                .font(.system(size: 13, weight: .semibold))
            Text("· \(session.agent.rawValue.capitalized) · \(session.status.rawValue)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: toggleStayOnTop) {
                Image(systemName: "pin")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .help("Toggle stay-on-top for this window")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func toggleStayOnTop() {
        guard let window = NSApp.keyWindow else { return }
        window.level = (window.level == .floating) ? .normal : .floating
    }

    private var bg: Color {
        colorScheme == .dark
            ? Color(red: 0.08, green: 0.08, blue: 0.08)
            : Color(red: 0.98, green: 0.98, blue: 0.98)
    }
}

/// Minimal chat-thread renderer reused inside PoppedOutSessionView. Mirrors
/// the main workspace's `ChatThreadScroll` but with no plan-card / no
/// review pane — just chat + send.
///
/// A5 — binds to messagesSlice (not the fat store), so the popped
/// chat doesn't re-render on token deltas or permission-prompt flips.
/// `store` is still held for the `send` action (`model.send(...)`
/// indirection takes care of dispatch; the view doesn't read other
/// store fields after migration).
private struct PoppedChatThread: View {
    let store: SessionChatStore
    @ObservedObject private var messagesSlice: ChatMessagesSlice
    let session: AgentSession
    @ObservedObject var model: SessionsModel
    @State private var composerText: String = ""
    @State private var expandedTurns: Set<String> = []
    @State private var projectionCache = SingleSlotProjectionCache<TranscriptProjectionCacheKey, TranscriptProjection>()

    init(store: SessionChatStore, session: AgentSession, model: SessionsModel) {
        self.store = store
        _messagesSlice = ObservedObject(wrappedValue: store.messagesSlice)
        self.session = session
        self.model = model
    }

    var body: some View {
        let projection = projectionCache.value(
            for: TranscriptProjectionCacheKey(
                updateCounter: messagesSlice.updateCounter,
                mode: .latestAnswerOnly
            )
        ) {
            TranscriptTurnProjector.project(
                items: messagesSlice.items,
                messages: messagesSlice.messages,
                mode: .latestAnswerOnly
            )
        }
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(projection.turns) { turn in
                        poppedTurnRow(turn)
                    }
                    Color.clear.frame(height: 8).id("bottom")
                }
                .padding(.vertical, 8)
            }
            Divider()
            HStack {
                TextField("Message the agent…", text: $composerText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    .lineLimit(1...5)
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(composerText.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(SessionsV2Theme.accent))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(composerText.isEmpty)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func poppedTurnRow(_ turn: TranscriptTurn) -> some View {
        if turn.prompt == nil {
            ForEach(turn.visibleItems) { item in poppedItemRow(item) }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(promptItems(turn)) { item in poppedItemRow(item) }
                poppedDisclosureRow(turn)
                if turn.hasCollapsedContent, expandedTurns.contains(turn.id) {
                    ForEach(turn.hiddenItems) { item in poppedItemRow(item) }
                }
                ForEach(finalItems(turn)) { item in poppedItemRow(item) }
                poppedChipStrip(turn)
            }
        }
    }

    @ViewBuilder
    private func poppedDisclosureRow(_ turn: TranscriptTurn) -> some View {
        let isOpen = expandedTurns.contains(turn.id)
        if turn.hasCollapsedContent {
            Button {
                if isOpen {
                    expandedTurns.remove(turn.id)
                } else {
                    expandedTurns.insert(turn.id)
                }
            } label: {
                Label(
                    turn.summary.disclosureLabel,
                    systemImage: isOpen ? "chevron.down" : "chevron.right"
                )
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
        } else {
            Label(turn.summary.disclosureLabel, systemImage: "clock")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
        }
    }

    @ViewBuilder
    private func poppedItemRow(_ item: ChatItem) -> some View {
        switch item {
        case .message(let msg):
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: msg.kind == .userText
                    ? "person.fill"
                    : (msg.kind == .toolCall ? "wrench" : "sparkle"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(ClawdmeterMac_displaySkillInvocations(in: msg.body))
                    .font(.system(size: 12, design: msg.kind == .toolCall ? .monospaced : .default))
                    .foregroundStyle(.primary)
                    .lineLimit(msg.kind == .toolResult ? 3 : nil)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 12)
            .id(msg.id)
        case .toolRun(_, let pairs):
            VStack(alignment: .leading, spacing: 5) {
                Text(pairs.count == 1 ? "Ran 1 command" : "Ran \(pairs.count) commands")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach(pairs) { pair in
                    Text("\(pair.call.title): \(pair.call.body)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .id("pair:\(pair.id)")
                }
            }
            .padding(.horizontal, 12)
        }
    }

    private func promptItems(_ turn: TranscriptTurn) -> [ChatItem] {
        guard let promptId = turn.prompt?.id else { return [] }
        return turn.visibleItems.filter {
            if case .message(let message) = $0 { return message.id == promptId }
            return false
        }
    }

    private func finalItems(_ turn: TranscriptTurn) -> [ChatItem] {
        let promptId = turn.prompt?.id
        return turn.visibleItems.filter {
            if case .message(let message) = $0 { return message.id != promptId }
            return true
        }
    }

    @ViewBuilder
    private func poppedChipStrip(_ turn: TranscriptTurn) -> some View {
        if !turn.outputArtifacts.isEmpty || !turn.editedFiles.isEmpty {
            HStack(spacing: 6) {
                ForEach(turn.outputArtifacts.prefix(4)) { artifact in
                    Button {
                        openPoppedArtifact(artifact)
                    } label: {
                        Label(artifact.filename, systemImage: artifact.kind == .markdown ? "doc.richtext" : "arrow.up.right.square")
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                }
                ForEach(turn.editedFiles.prefix(4)) { file in
                    Label(file.basename, systemImage: "pencil")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 34)
        }
    }

    private var transcriptPathRoot: URL? {
        for raw in [session.runtimeCwd, session.worktreePath, session.repoKey] {
            guard let path = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { continue }
            if path.hasPrefix("/") || path.hasPrefix("~") {
                return URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
            }
        }
        return nil
    }

    private func openPoppedArtifact(_ artifact: TranscriptOutputArtifact) {
        if artifact.kind == .markdown {
            model.openWorkspaceDocumentTab(from: session, path: artifact.path)
            return
        }
        guard let url = resolvedPoppedArtifactURL(artifact.path) else { return }
        NSWorkspace.shared.open(url)
    }

    private func resolvedPoppedArtifactURL(_ path: String) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("~") {
            return URL(fileURLWithPath: NSString(string: trimmed).expandingTildeInPath)
        }
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed)
        }
        return transcriptPathRoot?.appendingPathComponent(trimmed)
    }

    private func send() {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              let runtime = AppDelegate.runtime,
              let port = runtime.agentControlServer.boundPort
        else { return }
        composerText = ""
        let sender = MacComposerSender(
            port: Int(port),
            token: runtime.agentControlServer.localLoopbackToken
        )
        Task {
            try? await sender.send(sessionId: session.id, body: text, asFollowUp: true)
        }
    }
}

/// Zero-pixel SwiftUI helper that owns an `openWindow` environment action and
/// forwards `AppDelegate.openDashboardRequest` notifications to it. Lives
/// inside the dashboard window so it can call `openWindow(id:)`. Also
/// listens for `popOutSession` (G14) and opens a new session-detail window.
private struct DashboardOpener: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onReceive(NotificationCenter.default.publisher(for: AppDelegate.openDashboardRequest)) { _ in
                openWindow(id: "dashboard")
            }
            .onReceive(NotificationCenter.default.publisher(for: .popOutSession)) { note in
                guard let sessionId = note.userInfo?["sessionId"] as? UUID else { return }
                openWindow(id: "session-detail", value: sessionId)
            }
    }
}

/// cmd+, Settings.
struct PreferencesView: View {
    @ObservedObject var claudeModel: AppModel
    @ObservedObject var codexModel: AppModel
    @AppStorage(AppTheme.storageKey) private var themeRaw: String = AppTheme.system.rawValue

    var body: some View {
        Form {
            Section {
                Picker("Theme", selection: $themeRaw) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.displayName).tag(theme.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Appearance")
            }

            Section {
                Button("Force poll Claude") { claudeModel.forcePoll() }
                Button("Force poll Codex") { codexModel.forcePoll() }
            } header: {
                Text("Diagnostics")
            }
        }
        .padding(20)
        .frame(width: 440, height: 280)
        .preferredColorScheme(AppTheme(rawValue: themeRaw)?.colorScheme)
    }
}

import SwiftUI
import AppKit
import ClawdmeterShared

struct WorkspaceTabStrip: View {
    @ObservedObject var model: SessionsModel
    let workspaceKey: WorkspaceKey
    let activeSession: AgentSession?
    let activeSessionId: UUID?
    let draftTabs: [WorkspaceDraftTab]
    let activeDraftTabId: UUID?
    let terminalTabs: [WorkspaceTerminalTab]
    let activeTerminalTabId: UUID?
    let documentTabs: [WorkspaceDocumentTab]
    let activeDocumentTabId: UUID?
    let terminalAvailable: Bool
    let onNewChat: () -> Void
    let onNewTerminal: () -> Void
    let onSelectTerminal: (WorkspaceTerminalTab) -> Void
    let onCloseTerminal: (WorkspaceTerminalTab) -> Void
    let onSelectDocument: (WorkspaceDocumentTab) -> Void
    let onCloseDocument: (WorkspaceDocumentTab) -> Void

    @Environment(\.tahoe) private var t
    private static let newTabButtonId = "workspace-new-tab-button"
    private static let stripHorizontalPadding: CGFloat = 20
    private static let tabSpacing: CGFloat = 6
    private static let newTabButtonWidth: CGFloat = 26
    private static let chatTabChromeWidth: CGFloat = 49
    private static let idealLabelWidth: CGFloat = 118
    private static let expandedLabelWidth: CGFloat = 170

    private enum TabItem: Identifiable {
        case session(AgentSession)
        case draft(WorkspaceDraftTab)
        case terminal(WorkspaceTerminalTab, AgentSession)
        case document(WorkspaceDocumentTab)

        var id: String {
            switch self {
            case .session(let session): return "session-\(session.id.uuidString)"
            case .draft(let draft): return "draft-\(draft.id.uuidString)"
            case .terminal(let tab, _): return "terminal-\(tab.id.uuidString)"
            case .document(let tab): return "document-\(tab.id.uuidString)"
            }
        }

        var createdAt: Date {
            switch self {
            case .session(let session): return session.createdAt
            case .draft(let draft): return draft.createdAt
            case .terminal(let tab, _): return tab.createdAt
            case .document(let tab): return tab.createdAt
            }
        }
    }

    private var sessions: [AgentSession] {
        var grouped = WorkspaceKey.siblings(of: workspaceKey, in: model.registry.sessions)
        if let activeSession,
           activeSession.archivedAt == nil,
           !grouped.contains(where: { $0.id == activeSession.id }),
           WorkspaceKey.of(activeSession) == workspaceKey {
            grouped.append(activeSession)
            grouped.sort {
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                return $0.id.uuidString < $1.id.uuidString
            }
        }
        // Defensive: collapse any duplicate session-id so one session can't
        // render as two tabs (the registry dedupes on load, but guard the
        // render path too in case a duplicate slips in at runtime).
        var seen = Set<UUID>()
        return grouped.filter { seen.insert($0.id).inserted }
    }

    private var items: [TabItem] {
        var out = sessions.map(TabItem.session)
        for draftTab in draftTabs where draftTab.workspaceKey == workspaceKey {
            out.append(.draft(draftTab))
        }
        for tab in terminalTabs {
            guard tab.workspaceKey == workspaceKey,
                  let session = model.registry.session(id: tab.sessionId)
            else { continue }
            out.append(.terminal(tab, session))
        }
        for tab in documentTabs where tab.workspaceKey == workspaceKey {
            out.append(.document(tab))
        }
        return out.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id < $1.id
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let labelWidth = Self.adaptiveChatTabLabelWidth(
                availableWidth: geometry.size.width,
                itemCount: items.count
            )
            HStack(spacing: Self.tabSpacing) {
                ForEach(items) { item in
                    tabView(item, labelWidth: labelWidth)
                        .id(item.id)
                }
                newTabButton
            }
            .padding(.leading, Self.stripHorizontalPadding / 2)
            .padding(.trailing, Self.stripHorizontalPadding / 2)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
        }
        .frame(height: 40)
        .background(t.dark ? Color.white.opacity(0.035) : Color.black.opacity(0.025))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(t.hairline)
                .frame(height: 1)
        }
        .overlay(alignment: .topLeading) {
            Text("\(items.count)")
                .font(.system(size: 1))
                .foregroundStyle(.clear)
                .frame(width: 1, height: 1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(items.count)")
                .accessibilityIdentifier("code.workspace.tab-strip")
                .accessibilityValue("\(items.count)")
        }
    }

    static func adaptiveChatTabLabelWidth(availableWidth: CGFloat, itemCount: Int) -> CGFloat {
        guard itemCount > 0,
              availableWidth.isFinite,
              availableWidth > 0
        else { return Self.idealLabelWidth }

        let widthForLabels = availableWidth
            - Self.stripHorizontalPadding
            - Self.newTabButtonWidth
            - (CGFloat(itemCount) * Self.tabSpacing)
            - (CGFloat(itemCount) * Self.chatTabChromeWidth)
        let candidate = floor(widthForLabels / CGFloat(itemCount))
        return max(0, min(Self.expandedLabelWidth, candidate))
    }

    static func estimatedChatTabStripWidth(labelWidth: CGFloat, itemCount: Int) -> CGFloat {
        guard itemCount > 0 else {
            return Self.stripHorizontalPadding + Self.newTabButtonWidth
        }
        return Self.stripHorizontalPadding
            + Self.newTabButtonWidth
            + (CGFloat(itemCount) * Self.tabSpacing)
            + (CGFloat(itemCount) * (labelWidth + Self.chatTabChromeWidth))
    }

    @ViewBuilder
    private func tabView(_ item: TabItem, labelWidth: CGFloat) -> some View {
        switch item {
        case .session(let session):
            tabButton(for: session, labelWidth: labelWidth)
        case .draft(let draft):
            draftButton(draft, labelWidth: labelWidth)
        case .terminal(let tab, let session):
            terminalButton(tab, session: session, labelWidth: labelWidth)
        case .document(let tab):
            documentButton(tab, labelWidth: labelWidth)
        }
    }

    private var newTabButton: some View {
        Button(action: ContinuumAnalytics.wrapButton("workspace_new_tab", {
            DispatchQueue.main.async { onNewChat() }
        })) {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: Self.newTabButtonWidth, height: 26)
        }
        .id(Self.newTabButtonId)
        .buttonStyle(PressableButtonStyle())
        .codeHoverChrome(
            cornerRadius: 6,
            help: "New chat tab",
            accessibilityLabel: "New chat tab",
            accessibilityIdentifier: "code.workspace.new-tab"
        )
        .contextMenu {
            Button("Chat", action: ContinuumAnalytics.wrapButton("workspace_new_chat", {
                DispatchQueue.main.async { onNewChat() }
            }))
            .accessibilityIdentifier("code.workspace.new-tab.chat")
            Button("Terminal", action: ContinuumAnalytics.wrapButton("workspace_new_terminal", {
                DispatchQueue.main.async { onNewTerminal() }
            }))
            .disabled(!terminalAvailable)
            .accessibilityIdentifier("code.workspace.new-tab.terminal")
        }
    }

    private func tabButton(for session: AgentSession, labelWidth: CGFloat) -> some View {
        let isActive = activeTerminalTabId == nil
            && activeDocumentTabId == nil
            && session.id == activeSessionId
        let labels = WorkspaceSessionTabLabel.labels(for: session)
        return tabRow(
            title: labels.title,
            subtitle: labels.subtitle,
            systemImage: nil,
            isActive: isActive,
            labelWidth: labelWidth,
            selectAction: { model.openSession(session) },
            closeAction: { Task { await model.endSession(id: session.id) } }
        )
        .help(session.effectiveCwd)
        .accessibilityIdentifier("code.workspace.tab.session")
        .accessibilityValue("\(isActive ? "selected" : "not selected") \(session.id.uuidString) \(session.agent.rawValue) \(session.model ?? "")")
        .contextMenu {
            Button("Close", role: .destructive, action: ContinuumAnalytics.wrapButton("workspace_close_session", {
                Task { await model.endSession(id: session.id) }
            }))
            Button("Pop out window", action: ContinuumAnalytics.wrapButton("workspace_pop_out_session", {
                NotificationCenter.default.post(
                    name: .popOutSession,
                    object: nil,
                    userInfo: ["sessionId": session.id]
                )
            }))
        }
    }

    private func draftButton(_ draft: WorkspaceDraftTab, labelWidth: CGFloat) -> some View {
        let isActive = activeSessionId == nil
            && activeDraftTabId == draft.id
            && activeTerminalTabId == nil
            && activeDocumentTabId == nil
        return tabRow(
            title: "Untitled",
            subtitle: "Draft",
            systemImage: nil,
            isActive: isActive,
            labelWidth: labelWidth,
            selectAction: { model.selectDraftWorkspaceTab(draft) },
            closeAction: { model.clearDraftWorkspaceTab(draft) }
        )
        .help("Draft chat tab")
        .accessibilityIdentifier("code.workspace.tab.draft")
        .accessibilityValue("\(isActive ? "selected" : "not selected") \(draft.id.uuidString)")
    }

    private func terminalButton(_ tab: WorkspaceTerminalTab, session: AgentSession, labelWidth: CGFloat) -> some View {
        tabRow(
            title: terminalTitle(for: tab, session: session),
            subtitle: terminalSubtitle(for: session),
            systemImage: "terminal.fill",
            isActive: activeTerminalTabId == tab.id,
            labelWidth: labelWidth,
            selectAction: { onSelectTerminal(tab) },
            closeAction: { onCloseTerminal(tab) }
        )
        .help("\(terminalTitle(for: tab, session: session))\n\(session.effectiveCwd)")
        .accessibilityIdentifier("code.workspace.tab.terminal")
        .contextMenu {
            Button("Close", action: ContinuumAnalytics.wrapButton("workspace_close_terminal", {
                onCloseTerminal(tab)
            }))
        }
    }

    private func documentButton(_ tab: WorkspaceDocumentTab, labelWidth: CGFloat) -> some View {
        tabRow(
            title: tab.title,
            subtitle: "Document",
            systemImage: TranscriptArtifactClassifier.systemImageName(forPath: tab.path),
            isActive: activeDocumentTabId == tab.id,
            labelWidth: labelWidth,
            selectAction: { onSelectDocument(tab) },
            closeAction: { onCloseDocument(tab) }
        )
        .help(tab.path)
        .accessibilityIdentifier("code.workspace.tab.document")
        .contextMenu {
            Button("Close", action: ContinuumAnalytics.wrapButton("workspace_close_document", {
                onCloseDocument(tab)
            }))
            Button("Copy Path", action: ContinuumAnalytics.wrapButton("workspace_copy_document_path", {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(tab.path, forType: .string)
            }))
        }
    }

    /// Sibling select + close buttons (not nested) so clicking × never also
    /// selects or closes the wrong tab.
    private func tabRow(
        title: String,
        subtitle: String,
        systemImage: String?,
        isActive: Bool,
        labelWidth: CGFloat,
        selectAction: @escaping () -> Void,
        closeAction: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 7) {
            Button(action: ContinuumAnalytics.wrapButton("workspace_tab_select", selectAction)) {
                HStack(spacing: 7) {
                    if let systemImage {
                        Image(systemName: systemImage)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(isActive ? t.accent : t.fg3)
                    }
                    VStack(alignment: .leading, spacing: subtitle.isEmpty ? 0 : 1) {
                        Text(title)
                            .font(TahoeFont.body(12.5, weight: isActive ? .semibold : .medium))
                            .foregroundStyle(isActive ? t.fg : t.fg2)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if !subtitle.isEmpty {
                            Text(subtitle)
                                .font(TahoeFont.body(9.5))
                                .foregroundStyle(t.fg3)
                                .lineLimit(1)
                        }
                    }
                    .frame(width: labelWidth, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            Button(action: ContinuumAnalytics.wrapButton("workspace_tab_close", closeAction)) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .foregroundStyle(t.fg3)
            .codeHoverChrome(
                cornerRadius: 6,
                help: "Close tab",
                accessibilityLabel: "Close tab",
                accessibilityIdentifier: "code.workspace.tab.close"
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isActive ? t.surfaceSolid2.opacity(0.88) : Color.clear)
        )
        .overlay(alignment: .bottom) {
            if isActive {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(t.accent)
                    .frame(height: 2)
                    .padding(.horizontal, 8)
            }
        }
    }

    private func terminalTitle(for tab: WorkspaceTerminalTab, session: AgentSession) -> String {
        guard let paneRefId = tab.paneRefId,
              let pane = session.terminalPanes.first(where: { $0.id == paneRefId })
        else { return "Terminal" }
        let title = pane.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Terminal" : title
    }

    private func terminalSubtitle(for session: AgentSession) -> String {
        let branch = session.workspaceBranchLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty else { return "Terminal" }
        return "Terminal - \(branch)"
    }
}

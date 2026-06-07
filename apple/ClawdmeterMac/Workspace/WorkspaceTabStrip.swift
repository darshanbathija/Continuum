import SwiftUI
import AppKit
import ClawdmeterShared

struct WorkspaceTabStrip: View {
    @ObservedObject var model: SessionsModel
    let workspaceKey: WorkspaceKey
    let activeSession: AgentSession?
    let activeSessionId: UUID?
    let draftTab: WorkspaceDraftTab?
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
        return grouped
    }

    private var items: [TabItem] {
        var out = sessions.map(TabItem.session)
        if let draftTab, draftTab.workspaceKey == workspaceKey {
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
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(items) { item in
                    switch item {
                    case .session(let session):
                        tabButton(for: session)
                    case .draft:
                        draftButton
                    case .terminal(let tab, let session):
                        terminalButton(tab, session: session)
                    case .document(let tab):
                        documentButton(tab)
                    }
                }
                // New-tab button sits immediately after the last tab
                // (Chrome-style), not pinned to the window's right edge.
                Menu {
                    Button("Chat") { onNewChat() }
                        .keyboardShortcut("t", modifiers: [.command])
                    Button("Terminal") { onNewTerminal() }
                        .keyboardShortcut("t", modifiers: [.command, .shift])
                        .disabled(!terminalAvailable)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 26, height: 26)
                }
                .menuStyle(.borderlessButton)
                .help("New workspace tab")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
        .frame(height: 40)
        .background(t.dark ? Color.white.opacity(0.035) : Color.black.opacity(0.025))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(t.hairline)
                .frame(height: 1)
        }
    }

    private func tabButton(for session: AgentSession) -> some View {
        Button {
            model.openSession(session)
        } label: {
            tabLabel(
                title: title(for: session),
                subtitle: workspaceSubtitle(for: session),
                systemImage: nil,
                isActive: activeTerminalTabId == nil && activeDocumentTabId == nil && session.id == activeSessionId,
                closeAction: {
                    Task {
                        await model.endSession(id: session.id)
                    }
                }
            )
        }
        .buttonStyle(PressableButtonStyle())
        .help(session.effectiveCwd)
        .contextMenu {
            Button("Close", role: .destructive) {
                Task { await model.endSession(id: session.id) }
            }
            Button("Pop out window") {
                NotificationCenter.default.post(
                    name: .popOutSession,
                    object: nil,
                    userInfo: ["sessionId": session.id]
                )
            }
        }
    }

    private var draftButton: some View {
        Button { model.selectDraftWorkspaceTab() } label: {
            tabLabel(
                title: "Untitled",
                subtitle: "Draft",
                systemImage: nil,
                isActive: activeSessionId == nil && activeTerminalTabId == nil && activeDocumentTabId == nil,
                closeAction: { model.clearDraftWorkspaceTab() }
            )
        }
        .buttonStyle(PressableButtonStyle())
        .help("Draft chat tab")
    }

    private func terminalButton(_ tab: WorkspaceTerminalTab, session: AgentSession) -> some View {
        Button {
            onSelectTerminal(tab)
        } label: {
            tabLabel(
                title: terminalTitle(for: tab, session: session),
                subtitle: terminalSubtitle(for: session),
                systemImage: "terminal.fill",
                isActive: activeTerminalTabId == tab.id,
                closeAction: { onCloseTerminal(tab) }
            )
        }
        .buttonStyle(PressableButtonStyle())
        .help("\(terminalTitle(for: tab, session: session))\n\(session.effectiveCwd)")
        .contextMenu {
            Button("Close") {
                onCloseTerminal(tab)
            }
        }
    }

    private func documentButton(_ tab: WorkspaceDocumentTab) -> some View {
        Button {
            onSelectDocument(tab)
        } label: {
            tabLabel(
                title: tab.title,
                subtitle: "Document",
                systemImage: "doc.richtext",
                isActive: activeDocumentTabId == tab.id,
                closeAction: { onCloseDocument(tab) }
            )
        }
        .buttonStyle(PressableButtonStyle())
        .help(tab.path)
        .contextMenu {
            Button("Close") {
                onCloseDocument(tab)
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(tab.path, forType: .string)
            }
        }
    }

    private func tabLabel(
        title: String,
        subtitle: String,
        systemImage: String?,
        isActive: Bool,
        closeAction: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 7) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(isActive ? t.accent : t.fg3)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(TahoeFont.body(12.5, weight: isActive ? .semibold : .medium))
                    .foregroundStyle(isActive ? t.fg : t.fg2)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle)
                    .font(TahoeFont.body(9.5))
                    .foregroundStyle(t.fg3)
                    .lineLimit(1)
            }
            .frame(minWidth: 130, idealWidth: 160, maxWidth: 190, alignment: .leading)
            Button(action: closeAction) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(PressableButtonStyle())
            .foregroundStyle(t.fg3)
            .help("Close tab")
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

    private func title(for session: AgentSession) -> String {
        if let custom = session.customName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty {
            return custom
        }
        if let goal = session.goal?.trimmingCharacters(in: .whitespacesAndNewlines),
           !goal.isEmpty {
            return goal
        }
        return session.displayLabel
    }

    private func workspaceSubtitle(for session: AgentSession) -> String {
        let last = (WorkspaceKey.workspacePath(for: session) as NSString).lastPathComponent
        return last.isEmpty ? session.agent.rawValue : "\(session.agent.rawValue) - \(last)"
    }

    private func terminalTitle(for tab: WorkspaceTerminalTab, session: AgentSession) -> String {
        guard let paneRefId = tab.paneRefId,
              let pane = session.terminalPanes.first(where: { $0.id == paneRefId })
        else { return "Terminal" }
        let title = pane.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Terminal" : title
    }

    private func terminalSubtitle(for session: AgentSession) -> String {
        let last = (WorkspaceKey.workspacePath(for: session) as NSString).lastPathComponent
        return last.isEmpty ? "Shell" : "Shell - \(last)"
    }
}

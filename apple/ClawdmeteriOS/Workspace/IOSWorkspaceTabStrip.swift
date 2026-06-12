import SwiftUI
import ClawdmeterShared

struct IOSWorkspaceTabStrip: View {
    @Environment(\.tahoe) private var t

    let workspaceKey: WorkspaceKey
    let sessions: [AgentSession]
    let activeSessionId: UUID
    let terminalAvailable: Bool
    let documentTabs: [IOSWorkspaceDocumentTab]
    let activeDocumentTabId: UUID?
    let onOpenSession: (UUID) -> Void
    let onOpenTerminal: () -> Void
    let onSelectDocument: (IOSWorkspaceDocumentTab) -> Void
    let onCloseDocument: (IOSWorkspaceDocumentTab) -> Void

    private var workspaceSessions: [AgentSession] {
        WorkspaceKey.siblings(of: workspaceKey, in: sessions)
    }

    private var workspaceDocumentTabs: [IOSWorkspaceDocumentTab] {
        IOSWorkspaceDocumentTabs.tabs(in: workspaceKey, all: documentTabs)
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(workspaceSessions) { session in
                    Button {
                        onOpenSession(session.id)
                    } label: {
                        sessionChip(session)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(tabAccessibilityLabel(for: session)))
                }

                if terminalAvailable {
                    Button(action: onOpenTerminal) {
                        HStack(spacing: 6) {
                            Image(systemName: "terminal.fill")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Terminal")
                                .font(TahoeFont.body(11.5, weight: .semibold))
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                        .foregroundStyle(t.fg)
                        .background(t.glassTintHi, in: Capsule(style: .continuous))
                        .overlay {
                            Capsule(style: .continuous).stroke(t.hairline, lineWidth: 0.5)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Open Terminal tab"))
                }

                ForEach(workspaceDocumentTabs) { tab in
                    documentChip(tab)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 2)
        }
        .frame(height: 42)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func sessionChip(_ session: AgentSession) -> some View {
        let active = activeDocumentTabId == nil && session.id == activeSessionId
        HStack(spacing: 8) {
            TahoeProviderGlyph(provider: session.tahoeProvider, size: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title(for: session))
                    .font(TahoeFont.body(11.5, weight: active ? .bold : .semibold))
                    .foregroundStyle(active ? .white : t.fg)
                    .lineLimit(1)
                Text(subtitle(for: session))
                    .font(TahoeFont.body(9.5, weight: .medium))
                    .foregroundStyle(active ? Color.white.opacity(0.72) : t.fg3)
                    .lineLimit(1)
            }
            .frame(maxWidth: 126, alignment: .leading)
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .frame(height: 34)
        .background(active ? t.accent : t.glassTintHi, in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .stroke(active ? .clear : t.hairline, lineWidth: 0.5)
        }
        .overlay(alignment: .bottom) {
            if active {
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.92))
                    .frame(height: 2)
                    .padding(.horizontal, 18)
            }
        }
    }

    private func documentChip(_ tab: IOSWorkspaceDocumentTab) -> some View {
        let active = activeDocumentTabId == tab.id
        return HStack(spacing: 4) {
            Button {
                onSelectDocument(tab)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "doc.richtext")
                        .font(.system(size: 12, weight: .semibold))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(tab.title)
                            .font(TahoeFont.body(11.5, weight: active ? .bold : .semibold))
                            .lineLimit(1)
                        Text("Document")
                            .font(TahoeFont.body(9.5, weight: .medium))
                            .lineLimit(1)
                            .opacity(0.72)
                    }
                    .frame(maxWidth: 118, alignment: .leading)
                }
                .foregroundStyle(active ? .white : t.fg)
                .padding(.leading, 9)
                .padding(.trailing, 6)
                .frame(height: 34)
                .background(active ? t.accent : t.glassTintHi, in: Capsule(style: .continuous))
                .overlay {
                    Capsule(style: .continuous)
                        .stroke(active ? .clear : t.hairline, lineWidth: 0.5)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(active ? "\(tab.title), current document tab" : "Open \(tab.title) document tab"))

            Button {
                onCloseDocument(tab)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(active ? Color.white.opacity(0.88) : t.fg3)
                    .frame(width: 24, height: 34)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Close \(tab.title) document tab"))
        }
        .background(active ? t.accent : t.glassTintHi, in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .stroke(active ? .clear : t.hairline, lineWidth: 0.5)
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

    private func subtitle(for session: AgentSession) -> String {
        let workspace = (WorkspaceKey.workspacePath(for: session) as NSString).lastPathComponent
        if workspace.isEmpty {
            return session.agent.rawValue
        }
        return "\(session.agent.rawValue) - \(workspace)"
    }

    private func tabAccessibilityLabel(for session: AgentSession) -> String {
        if activeDocumentTabId == nil && session.id == activeSessionId {
            return "\(title(for: session)), current workspace tab"
        }
        return "Open \(title(for: session)) workspace tab"
    }
}

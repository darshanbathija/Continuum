import SwiftUI
import ClawdmeterShared

struct IOSWorkspaceTabStrip: View {
    @Environment(\.tahoe) private var t

    let workspaceKey: WorkspaceKey
    let sessions: [AgentSession]
    let activeSessionId: UUID
    let terminalAvailable: Bool
    let onOpenSession: (UUID) -> Void
    let onOpenTerminal: () -> Void

    private var workspaceSessions: [AgentSession] {
        WorkspaceKey.siblings(of: workspaceKey, in: sessions)
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
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 2)
        }
        .frame(height: 42)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func sessionChip(_ session: AgentSession) -> some View {
        let active = session.id == activeSessionId
        HStack(spacing: 8) {
            TahoeProviderGlyph(provider: session.agent.tahoeProvider, size: 18)
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
        if session.id == activeSessionId {
            return "\(title(for: session)), current workspace tab"
        }
        return "Open \(title(for: session)) workspace tab"
    }
}

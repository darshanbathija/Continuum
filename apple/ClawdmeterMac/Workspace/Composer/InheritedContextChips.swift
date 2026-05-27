import SwiftUI
import ClawdmeterShared

struct InheritedContextChips: View {
    let siblings: [AgentSession]
    @Binding var selectedSourceIds: Set<UUID>

    @Environment(\.tahoe) private var t

    var body: some View {
        TahoeGlass(radius: 12, tone: .raised, shadow: .subtle) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "text.bubble.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(t.accent)
                        .frame(width: 24, height: 24)
                        .background(t.accentAlpha(t.dark ? 0.18 : 0.12), in: RoundedRectangle(cornerRadius: 7))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("Inherit sibling context")
                                .font(TahoeFont.body(12.5, weight: .semibold))
                                .foregroundStyle(t.fg)
                            infoPopover
                        }
                        Text(selectionSummary)
                            .font(TahoeFont.body(11))
                            .foregroundStyle(t.fg3)
                            .lineLimit(2)
                    }
                    Spacer()
                }
                if siblings.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(t.fg4)
                        Text("No sibling chats in this workspace yet")
                            .font(TahoeFont.body(11.5, weight: .medium))
                            .foregroundStyle(t.fg3)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(t.surfaceSolid2.opacity(0.62), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(t.hairline, lineWidth: 0.75)
                    )
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(siblings) { session in
                                chip(for: session)
                            }
                        }
                        .padding(.vertical, 1)
                    }
                }
            }
            .padding(12)
        }
        .frame(maxWidth: 760, alignment: .leading)
    }

    private var infoPopover: some View {
        Menu {
            Text("Selected sibling transcripts are rendered into bounded markdown digests.")
            Text("Plans, sources, and artifacts are summarized.")
            Text("Attachments are copied into this new session with a manifest.")
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(t.fg3)
        }
        .menuStyle(.borderlessButton)
        .help("What gets inherited?")
    }

    private var selectionSummary: String {
        let count = selectedSourceIds.count
        if siblings.isEmpty {
            return "This draft is ready without inherited context. New sibling chats will appear here for opt-in."
        }
        if count == 0 {
            return "Opt in to prior tabs before sending. Digests and copied attachments are auditable in the new session."
        }
        if count == 1 {
            return "1 transcript will be attached as a bounded digest."
        }
        return "\(count) transcripts will be attached as bounded digests."
    }

    private func chip(for session: AgentSession) -> some View {
        let selected = selectedSourceIds.contains(session.id)
        return Button {
            if selected {
                selectedSourceIds.remove(session.id)
            } else {
                selectedSourceIds.insert(session.id)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(selected ? t.accent : t.fg4)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title(for: session))
                        .font(TahoeFont.body(11.5, weight: .semibold))
                        .foregroundStyle(selected ? t.fg : t.fg2)
                        .lineLimit(1)
                    Text(meta(for: session))
                        .font(TahoeFont.body(10.5))
                        .foregroundStyle(t.fg3)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(minWidth: 132, maxWidth: 220, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(selected ? t.accentAlpha(t.dark ? 0.18 : 0.12) : t.surfaceSolid2.opacity(0.70))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(selected ? t.accentAlpha(0.65) : t.hairline, lineWidth: 0.75)
            )
        }
        .buttonStyle(.plain)
        .help("\(session.agent.rawValue) - \(WorkspaceKey.workspacePath(for: session))")
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

    private func meta(for session: AgentSession) -> String {
        "\(session.agent.rawValue.capitalized) - \(session.status.rawValue)"
    }
}

import SwiftUI
import ClawdmeterShared

/// Side-by-side comparison sheet for two sessions. Surfaces the
/// summary fields (repo, branch, last event, plan presence, PR, TODOs)
/// plus a short transcript preview. Presented as a `.sheet` from the
/// sidebar's context menu.
///
/// Lifted out of `SessionWorkspaceView.swift` by **A6 (foundation)** —
/// see .claude/plans/study-this-codebase-crystalline-shore.md. The
/// sheet's body only observes `SessionsModel` (for `chatStore(for:)`
/// lookups) plus the two `AgentSession` value props it was constructed
/// with — fully independent of the parent workspace's @State.

/// Tuple type that pairs two sessions with a stable Identifiable id, so
/// the comparison sheet can be presented via `.sheet(item:)`.
struct SessionComparisonPair: Identifiable {
    let left: AgentSession
    let right: AgentSession

    var id: String { "\(left.id.uuidString)-\(right.id.uuidString)" }
}

struct SessionComparisonSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.tahoe) private var t
    let pair: SessionComparisonPair
    @ObservedObject var model: SessionsModel

    var body: some View {
        // A6 (foundation): body-invalidation tap. No-op in production.
        BodyInvalidationCounter.bump("SessionComparisonSheet")
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Compare Sessions")
                    .font(TahoeFont.body(18, weight: .bold))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            HStack(alignment: .top, spacing: 12) {
                comparisonColumn(pair.left)
                comparisonColumn(pair.right)
            }
        }
        .padding(18)
        .frame(minWidth: 760, minHeight: 430)
        .background(t.pageBg)
    }

    private func comparisonColumn(_ session: AgentSession) -> some View {
        let store = model.chatStore(for: session)
        let todos = store?.snapshot.codexTodos ?? []
        let openTodos = todos.filter { $0.status != "completed" }.count
        return TahoeGlass(radius: 6, tone: .panel) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    TahoeProviderGlyph(provider: session.agent.tahoeProvider, size: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.displayLabel)
                            .font(TahoeFont.body(13, weight: .bold))
                            .lineLimit(1)
                        Text("\(session.agent.rawValue) · \(session.status.rawValue)")
                            .font(TahoeFont.mono(10.5))
                            .foregroundStyle(t.fg3)
                    }
                }
                comparisonRow("Repo", session.repoDisplayName)
                comparisonRow("Branch", session.prMirrorState?.branchName ?? session.worktreePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "none")
                comparisonRow("Last event", Self.relative(session.lastEventAt))
                comparisonRow("Plan", session.planText == nil ? "none" : "present")
                comparisonRow("PR", session.prMirrorState?.prURL ?? "none")
                comparisonRow("TODOs", todos.isEmpty ? "none" : "\(openTodos) open / \(todos.count) total")
                TahoeHairline()
                Text("Recent Activity")
                    .font(TahoeFont.body(11, weight: .semibold))
                    .foregroundStyle(t.fg3)
                Text(activityPreview(for: session, store: store))
                    .font(TahoeFont.body(11.5))
                    .foregroundStyle(t.fg2)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .textSelection(.enabled)
                Spacer()
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, minHeight: 350, alignment: .topLeading)
    }

    private func comparisonRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(TahoeFont.body(10.5, weight: .semibold))
                .foregroundStyle(t.fg3)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(TahoeFont.body(11.5))
                .foregroundStyle(t.fg)
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    private func activityPreview(for session: AgentSession, store: SessionChatStore?) -> String {
        if let last = store?.snapshot.items.last {
            return String(describing: last).prefix(700).description
        }
        return session.goal ?? session.customName ?? "No transcript rows loaded for this session yet."
    }

    private static func relative(_ date: Date) -> String {
        RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
    }
}

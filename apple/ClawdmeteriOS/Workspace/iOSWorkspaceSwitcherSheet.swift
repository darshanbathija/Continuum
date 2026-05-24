import SwiftUI
import ClawdmeterShared

struct iOSWorkspaceSwitcherSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.tahoe) private var t
    @ObservedObject var client: AgentControlClient
    let onOpenSession: (UUID) -> Void
    let onNewSession: () -> Void

    @State private var query = ""
    @State private var workspaces: [CodeWorkspaceRecord] = []
    @State private var isLoading = true

    private var sessions: [AgentSession] {
        client.sessions.sorted { $0.lastEventAt > $1.lastEventAt }
    }

    private var visibleWorkspaces: [CodeWorkspaceRecord] {
        let q = normalized(query)
        guard !q.isEmpty else { return workspaces.sorted { $0.updatedAt > $1.updatedAt } }
        return workspaces.filter {
            normalized($0.repoDisplayName).contains(q)
                || normalized($0.runtimeCwd).contains(q)
                || normalized($0.branchName ?? "").contains(q)
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var visibleSessions: [AgentSession] {
        let q = normalized(query)
        guard !q.isEmpty else { return sessions }
        return sessions.filter {
            normalized($0.displayLabel).contains(q)
                || normalized($0.repoDisplayName).contains(q)
                || normalized($0.effectiveCwd).contains(q)
                || normalized(AgentKindUI.displayName(for: $0.agent)).contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Switch workspace or session", text: $query)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }

                if isLoading {
                    Section {
                        HStack {
                            ProgressView()
                            Text("Loading workspaces...")
                        }
                    }
                }

                if !visibleWorkspaces.isEmpty {
                    Section("Workspaces") {
                        ForEach(visibleWorkspaces) { workspace in
                            workspaceRow(workspace)
                        }
                    }
                }

                Section("Sessions") {
                    if visibleSessions.isEmpty {
                        ContentUnavailableView(
                            "No matching sessions",
                            systemImage: "rectangle.stack",
                            description: Text("Run or start an agent in a repo and it will appear here.")
                        )
                    } else {
                        ForEach(visibleSessions) { session in
                            sessionRow(session)
                        }
                    }
                }
            }
            .navigationTitle("Switch Workspace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                        onNewSession()
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .task { await loadWorkspaces() }
            .refreshable { await loadWorkspaces() }
        }
    }

    private func workspaceRow(_ workspace: CodeWorkspaceRecord) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 9) {
                Image(systemName: workspace.archiveMetadata?.archivedAt == nil ? "folder" : "archivebox")
                    .foregroundStyle(workspace.archiveMetadata?.archivedAt == nil ? t.accent : t.fg4)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(workspace.repoDisplayName)
                        .font(TahoeFont.body(13.5, weight: .semibold))
                    Text(workspace.branchName ?? workspace.defaultBranch ?? "workspace")
                        .font(TahoeFont.body(11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(workspace.activeSessionIds.count)")
                    .font(TahoeFont.mono(11, weight: .bold))
                    .foregroundStyle(t.fg3)
            }
            Text(workspace.runtimeCwd)
                .font(TahoeFont.mono(10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            if let first = workspace.activeSessionIds.first {
                Button {
                    dismiss()
                    onOpenSession(first)
                } label: {
                    Label("Open latest session", systemImage: "arrow.right.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    private func sessionRow(_ session: AgentSession) -> some View {
        Button {
            dismiss()
            onOpenSession(session.id)
        } label: {
            HStack(spacing: 10) {
                StatusPulse(color: statusColor(session), isLive: session.status == .running)
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.displayLabel)
                        .font(TahoeFont.body(13.5, weight: .semibold))
                        .foregroundStyle(t.fg)
                        .lineLimit(1)
                    Text("\(AgentKindUI.displayName(for: session.agent)) · \(session.repoDisplayName)")
                        .font(TahoeFont.body(11.5))
                        .foregroundStyle(t.fg3)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @MainActor
    private func loadWorkspaces() async {
        isLoading = true
        await client.refreshSessions()
        workspaces = await client.listWorkspaces()
        isLoading = false
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func statusColor(_ session: AgentSession) -> Color {
        if session.archivedAt != nil { return .secondary }
        if session.planText?.isEmpty == false || session.status == .planning { return t.accent }
        switch session.status {
        case .running: return .green
        case .paused, .degraded: return .orange
        case .done: return .blue
        case .planning: return t.accent
        }
    }
}

private struct StatusPulse: View {
    let color: Color
    let isLive: Bool

    var body: some View {
        ZStack {
            if isLive {
                Circle()
                    .stroke(color.opacity(0.28), lineWidth: 4)
                    .frame(width: 18, height: 18)
            }
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
        }
        .frame(width: 22, height: 22)
    }
}

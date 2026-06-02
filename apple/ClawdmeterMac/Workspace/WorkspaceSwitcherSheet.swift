import SwiftUI
import ClawdmeterShared

/// Modal Cmd+Shift+O switcher. Filters across active sessions + repos
/// by a live search query and lets the user open a session, jump to a
/// repo's last session, or start a new one. Presented from the
/// workspace's overlay.
///
/// Lifted out of `SessionWorkspaceView.swift` by **A6 (foundation)** —
/// see .claude/plans/study-this-codebase-crystalline-shore.md. Owns its
/// own `@State query` + `@FocusState searchFocused`; the parent only
/// drives `isPresented`. Independent of the parent workspace's @State
/// graph — the only shared observation is the `SessionsModel` itself.
struct WorkspaceSwitcherSheet: View {
    @ObservedObject var model: SessionsModel
    let focusedSession: AgentSession?
    @Binding var isPresented: Bool
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var filteredSessions: [AgentSession] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let sessions = model.registry.sessions
            .filter { $0.archivedAt == nil }
            .sorted { $0.lastEventAt > $1.lastEventAt }
        guard !q.isEmpty else { return Array(sessions.prefix(50)) }
        return sessions.filter { session in
            session.displayLabel.lowercased().contains(q)
                || session.repoDisplayName.lowercased().contains(q)
                || session.agent.rawValue.lowercased().contains(q)
        }
    }

    private var filteredRepos: [AgentRepo] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let repos = model.repos
        guard !q.isEmpty else { return Array(repos.prefix(20)) }
        return repos.filter { repo in
            repo.displayName.lowercased().contains(q)
                || repo.key.lowercased().contains(q)
        }
    }

    var body: some View {
        // A6 (foundation): tap the body-invalidation counter so the
        // independence test can assert the sheet's body does NOT re-run
        // when the parent workspace's @State (e.g. modeSwitchOverlay)
        // toggles. No-op in production.
        BodyInvalidationCounter.bump("WorkspaceSwitcherSheet")
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Switch workspace or session", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($searchFocused)
                    .onSubmit { activateDefaultResult() }
                Button("New") {
                    model.showingNewSessionSheet = true
                    isPresented = false
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(12)
            Divider()
            List {
                if let focusedSession,
                   let repoKey = focusedSession.repoKey {
                    Section("Current Repo") {
                        Button {
                            model.selectedRepoKey = repoKey
                            model.showingNewSessionSheet = true
                            isPresented = false
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "plus.circle.fill")
                                    .foregroundStyle(.green)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Start new session in \(focusedSession.repoDisplayName)")
                                        .font(.system(size: 12, weight: .semibold))
                                        .lineLimit(1)
                                    Text(repoKey)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                        }
                        .buttonStyle(PressableButtonStyle())
                    }
                }
                if !filteredSessions.isEmpty {
                    Section("Sessions") {
                        ForEach(filteredSessions) { session in
                            Button {
                                model.openOutsideJSONLPath = nil
                                model.openSessionId = session.id
                                isPresented = false
                            } label: {
                                workspaceSessionRow(session)
                            }
                            .buttonStyle(PressableButtonStyle())
                        }
                    }
                }
                if !filteredRepos.isEmpty {
                    Section("Repos") {
                        ForEach(filteredRepos, id: \.key) { repo in
                            Button {
                                model.selectedRepoKey = repo.key
                                model.showingNewSessionSheet = true
                                isPresented = false
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "folder.fill")
                                        .foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(repo.displayName)
                                            .font(.system(size: 12, weight: .semibold))
                                            .lineLimit(1)
                                        Text(repo.key)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                    Spacer()
                                    Image(systemName: "plus.circle")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(PressableButtonStyle())
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            Button("Open") {
                activateDefaultResult()
            }
            .keyboardShortcut(.defaultAction)
            .opacity(0)
            .frame(width: 0, height: 0)
            Button("Cancel") {
                isPresented = false
            }
            .keyboardShortcut(.cancelAction)
            .opacity(0)
            .frame(width: 0, height: 0)
        }
        .frame(minWidth: 520, minHeight: 460)
        .onAppear {
            searchFocused = true
        }
    }

    private func activateDefaultResult() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty,
           let focusedSession,
           let repoKey = focusedSession.repoKey {
            openRepo(repoKey)
            return
        }
        if let session = filteredSessions.first {
            openSession(session)
            return
        }
        if let repo = filteredRepos.first {
            openRepo(repo.key)
        }
    }

    private func openSession(_ session: AgentSession) {
        model.openOutsideJSONLPath = nil
        model.openSessionId = session.id
        isPresented = false
    }

    private func openRepo(_ repoKey: String) {
        model.selectedRepoKey = repoKey
        model.showingNewSessionSheet = true
        isPresented = false
    }

    private func workspaceSessionRow(_ session: AgentSession) -> some View {
        HStack(spacing: 8) {
            StatusPulseDot(
                color: session.status == .running ? .green : .secondary,
                isLive: session.status == .running
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text("\(session.repoDisplayName) · \(session.agent.rawValue.capitalized) · \(session.status.rawValue)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(session.lastEventAt.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
    }
}

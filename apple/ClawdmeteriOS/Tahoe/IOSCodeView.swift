import SwiftUI
import ClawdmeterShared

/// iOS Code (Sessions) tab — search + per-repo expandable cards with a
/// new-session "+" button per repo. Ports `ios-live.jsx::IOSSessions`.
/// Accepts a `TahoeCodeBindings` value (defaults to demo); ContentView/iOS
/// root injects daemon-derived bindings via the AgentControlClient adapter.
public struct IOSCodeView: View {
    @Environment(\.tahoe) private var t
    /// Push the session detail screen for a specific session id. Carries
    /// the id so the detail surface can render real session data instead
    /// of a hardcoded fixture (P1 fix).
    var onOpenDetail: (UUID) -> Void
    /// Present the NewSessionSheet. Wired from IOSRootView so the sheet
    /// has access to the AgentControlClient.
    var onNewSession: () -> Void
    public var data: TahoeCodeBindings
    /// PR #35: daemon client passed down so the recent-session row can
    /// call `unarchiveSession(id:)` when the user taps an archived
    /// entry. Nil keeps the row read-only (Previews + cold-launch).
    var agentClient: AgentControlClient?

    public init(
        data: TahoeCodeBindings = .demo,
        onOpenDetail: @escaping (UUID) -> Void = { _ in },
        onNewSession: @escaping () -> Void = {},
        agentClient: AgentControlClient? = nil
    ) {
        self.data = data
        self.onOpenDetail = onOpenDetail
        self.onNewSession = onNewSession
        self.agentClient = agentClient
    }

    @State private var searchQuery: String = ""

    public var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                IOSLargeTitle(title: "Code") {
                    IOSRoundIconBtn("plus", action: onNewSession)
                }

                // Search — PR #26 D5. Real TextField that filters
                // sessions by title + goal across visible repos.
                TahoeGlass(radius: 14, tone: .chip) {
                    HStack(spacing: 10) {
                        TahoeIcon("search", size: 15).foregroundStyle(t.fg3)
                        TextField("Search sessions…", text: $searchQuery)
                            .textFieldStyle(.plain)
                            .font(TahoeFont.body(14))
                            .foregroundStyle(t.fg)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        if !searchQuery.isEmpty {
                            Button {
                                searchQuery = ""
                            } label: {
                                TahoeIcon("x", size: 12).foregroundStyle(t.fg3)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 38)
                }
                .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 12)

                // Repo sections — apply the search query if non-empty.
                let visible = filteredRepos
                if visible.isEmpty {
                    VStack(spacing: 8) {
                        TahoeIcon("chat", size: 22).foregroundStyle(t.fg4)
                        Text("No active sessions")
                            .font(TahoeFont.body(14, weight: .semibold))
                            .foregroundStyle(t.fg2)
                        Text("Sessions started on your Mac will appear here once you're paired.")
                            .font(TahoeFont.body(12))
                            .foregroundStyle(t.fg3)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 280)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 60)
                    .padding(.horizontal, 24)
                } else {
                    VStack(spacing: 14) {
                        ForEach(visible) { repo in
                            IOSRepoCard(
                                repo: repo,
                                onOpen: onOpenDetail,
                                onNewSession: onNewSession,
                                agentClient: agentClient
                            )
                        }
                    }
                    .padding(.horizontal, 16).padding(.bottom, 30)
                }
            }
        }
    }

    /// PR #26 D5: filter repos + sessions by `searchQuery`. Empty query
    /// is identical to today's behavior (regression-safe).
    private var filteredRepos: [TahoeCodeRepo] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let baseline = data.repos.filter { !$0.sessions.isEmpty || !$0.recents.isEmpty }
        guard !query.isEmpty else { return baseline }
        return baseline.compactMap { repo in
            let matchedSessions = repo.sessions.filter { s in
                s.title.lowercased().contains(query)
            }
            // Also match the repo name itself — typing "ccwatch" should
            // surface that repo even if no session title matches.
            let repoMatches = repo.name.lowercased().contains(query)
            if matchedSessions.isEmpty && !repoMatches { return nil }
            return TahoeCodeRepo(
                key: repo.key,
                name: repo.name,
                tint: repo.tint,
                liveSessionCount: repo.liveSessionCount,
                sessions: repoMatches ? repo.sessions : matchedSessions,
                recents: repo.recents
            )
        }
    }
}

private struct IOSRepoCard: View {
    @Environment(\.tahoe) private var t
    var repo: TahoeCodeRepo
    var onOpen: (UUID) -> Void
    var onNewSession: () -> Void
    /// PR #35: daemon client used by the recent-row tap handler to
    /// call `unarchiveSession(id:)`. Nil keeps the row read-only.
    var agentClient: AgentControlClient?
    @State private var restoringSessionId: UUID? = nil

    @State private var expanded: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    expanded.toggle()
                } label: {
                    HStack(spacing: 8) {
                        TahoeIcon(expanded ? "chevD" : "chevR", size: 11).foregroundStyle(t.fg3)
                        TahoeProjectGlyph(name: repo.name, tint: repo.tint, size: 22)
                        Text(repo.name)
                            .font(TahoeFont.body(14, weight: .bold))
                            .tracking(-0.1)
                            .foregroundStyle(t.fg)
                        if repo.liveSessionCount > 0 {
                            HStack(spacing: 4) {
                                Circle().fill(Color(.sRGB, red: 0x28/255.0, green: 0xC8/255.0, blue: 0x40/255.0))
                                    .frame(width: 6, height: 6)
                                    .shadow(color: Color(.sRGB, red: 0x28/255.0, green: 0xC8/255.0, blue: 0x40/255.0), radius: 3, x: 0, y: 0)
                                Text("\(repo.liveSessionCount) live")
                                    .font(TahoeFont.body(11, weight: .bold))
                                    .foregroundStyle(Color(.sRGB, red: 0x28/255.0, green: 0xC8/255.0, blue: 0x40/255.0))
                            }
                        }
                        Spacer()
                        Text("\(repo.sessions.count) session\(repo.sessions.count == 1 ? "" : "s")")
                            .font(TahoeFont.mono(11))
                            .foregroundStyle(t.fg4)
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)

                Button(action: onNewSession) {
                    TahoeIcon("plus", size: 15).foregroundStyle(t.fg2)
                        .frame(width: 38, height: 38)
                        .background {
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(t.dark ? Color(.sRGB, white: 1, opacity: 0.06) : Color(.sRGB, white: 15.0/255, opacity: 0.05))
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(t.hairline, lineWidth: 0.5)
                        }
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 4).padding(.bottom, 8)

            if expanded {
                TahoeGlass(radius: 20, tone: .raised) {
                    VStack(spacing: 0) {
                        ForEach(Array(repo.sessions.enumerated()), id: \.offset) { i, s in
                            if i > 0 {
                                TahoeHair().padding(.leading, 58)
                            }
                            Button(action: { onOpen(s.id) }) {
                                HStack(spacing: 12) {
                                    TahoeProviderGlyph(provider: s.agent, size: 32)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(s.title)
                                            .font(TahoeFont.body(14, weight: .semibold))
                                            .foregroundStyle(t.fg)
                                            .lineLimit(1)
                                        HStack(spacing: 6) {
                                            StatusDot(status: s.status)
                                            Text(s.subtitle)
                                                .font(TahoeFont.body(11.5))
                                                .foregroundStyle(t.fg3)
                                        }
                                    }
                                    Spacer()
                                    TahoeIcon("chevR", size: 14).foregroundStyle(t.fg4)
                                }
                                .padding(.horizontal, 16).padding(.vertical, 14)
                            }
                            .buttonStyle(.plain)
                        }
                        if !repo.recents.isEmpty {
                            TahoeHair()
                            Text("RECENT")
                                .font(TahoeFont.body(10.5, weight: .bold))
                                .tracking(0.5)
                                .foregroundStyle(t.fg4)
                                .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            ForEach(Array(repo.recents.enumerated()), id: \.offset) { i, r in
                                if i > 0 {
                                    TahoeHair().padding(.leading, 58)
                                }
                                // PR #35: archived sessions carry a real
                                // sessionId so tapping calls the daemon's
                                // unarchive RPC + pushes the session
                                // detail screen on success. Recents
                                // without a sessionId stay non-tappable
                                // (read-only history entries).
                                let restoreInFlight = (restoringSessionId == r.sessionId)
                                let canRestore = (r.sessionId != nil && agentClient != nil)
                                Button {
                                    guard let sid = r.sessionId,
                                          let client = agentClient,
                                          !restoreInFlight else { return }
                                    restoringSessionId = sid
                                    Task { @MainActor in
                                        await client.unarchiveSession(id: sid)
                                        await client.refreshSessions()
                                        restoringSessionId = nil
                                        onOpen(sid)
                                    }
                                } label: {
                                    HStack(spacing: 12) {
                                        ZStack {
                                            TahoeProviderGlyph(provider: r.provider, size: 28)
                                            if r.live {
                                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                    .stroke(Color(.sRGB, red: 0x28/255.0, green: 0xC8/255.0, blue: 0x40/255.0), lineWidth: 1.5)
                                                    .padding(-2)
                                            }
                                        }
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(r.title)
                                                .font(TahoeFont.body(14))
                                                .foregroundStyle(t.fg2)
                                                .lineLimit(1)
                                            Text("\(r.provider.displayName) · \(r.ago)")
                                                .font(TahoeFont.body(11))
                                                .foregroundStyle(t.fg4)
                                        }
                                        Spacer()
                                        if restoreInFlight {
                                            ProgressView().controlSize(.mini)
                                        } else {
                                            TahoeIcon("chevR", size: 13)
                                                .foregroundStyle(canRestore ? t.fg2 : t.fg4)
                                        }
                                    }
                                    .padding(.horizontal, 16).padding(.vertical, 12)
                                    .opacity(canRestore ? 1.0 : 0.7)
                                }
                                .buttonStyle(.plain)
                                .disabled(!canRestore || restoreInFlight)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct StatusDot: View {
    @Environment(\.tahoe) private var t
    var status: TahoeCodeSession.Status

    var body: some View {
        let c: Color = {
            switch status {
            case .running:  return Color(.sRGB, red: 0x28/255.0, green: 0xC8/255.0, blue: 0x40/255.0)
            case .planning: return t.fg3
            case .paused:   return Color(.sRGB, red: 0xFE/255.0, green: 0xBC/255.0, blue: 0x2E/255.0)
            case .done:     return t.accent
            case .degraded: return Color(.sRGB, red: 1, green: 0x5F/255.0, blue: 0x57/255.0)
            }
        }()
        Circle().fill(c)
            .frame(width: 7, height: 7)
            .shadow(color: status == .running ? c : .clear, radius: 3, x: 0, y: 0)
    }
}

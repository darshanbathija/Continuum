import SwiftUI
import ClawdmeterShared
#if canImport(UIKit)
import UIKit
#endif

/// iOS Code (Sessions) tab — search + production session cards.
/// Ports `ios-live.jsx::IOSSessions`.
/// Accepts a `TahoeCodeBindings` value (defaults to demo); ContentView/iOS
/// root injects daemon-derived bindings via the AgentControlClient adapter.
public struct IOSCodeView: View {
    @Environment(\.tahoe) private var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private enum StatusScope: String, CaseIterable, Identifiable {
        case all, active, review, done, archived
        var id: String { rawValue }

        var label: String {
            switch self {
            case .all: return "All"
            case .active: return "Active"
            case .review: return "Review"
            case .done: return "Done"
            case .archived: return "Archived"
            }
        }

        var icon: String {
            switch self {
            case .all: return "chat"
            case .active: return "bolt"
            case .review: return "sparkles"
            case .done: return "check"
            case .archived: return "archive"
            }
        }
    }

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
    var outbox: MobileCommandOutbox?
    @ObservedObject var presentationStore: SessionPresentationStore
    var onPairWithDesktop: () -> Void

    public init(
        data: TahoeCodeBindings = .demo,
        onOpenDetail: @escaping (UUID) -> Void = { _ in },
        onNewSession: @escaping () -> Void = {},
        agentClient: AgentControlClient? = nil,
        outbox: MobileCommandOutbox? = nil,
        presentationStore: SessionPresentationStore? = nil,
        onPairWithDesktop: @escaping () -> Void = {}
    ) {
        self.data = data
        self.onOpenDetail = onOpenDetail
        self.onNewSession = onNewSession
        self.agentClient = agentClient
        self.outbox = outbox
        self.presentationStore = presentationStore ?? Self.defaultPresentationStore()
        self.onPairWithDesktop = onPairWithDesktop
    }

    private static func defaultPresentationStore() -> SessionPresentationStore {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return SessionPresentationStore(
            storeURL: SessionPresentationStore.defaultStoreURL(appSupportDirectory: appSupport)
        )
    }

    @State private var searchQuery: String = ""
    @State private var statusScope: StatusScope = .all
    @State private var providerFilter: TahoeProvider?
    @State private var includeRecents: Bool = true
    @State private var filtersDialogPresented: Bool = false
    @State private var workspaceSwitcherPresented: Bool = false

    public var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    IOSRoundIconBtn("folder", action: { workspaceSwitcherPresented = true })
                    if let agentClient {
                        IOSDesktopSyncBadge(client: agentClient, onPair: onPairWithDesktop)
                    }
                    Spacer()
                    IOSRoundIconBtn("plus", action: onNewSession)
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 10)

                if let agentClient {
                    IOSDesktopPairingCTA(client: agentClient, onPair: onPairWithDesktop)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 10)
                }

                // Search — PR #26 D5. Real TextField that filters
                // sessions by title + goal across visible repos.
                TahoeGlass(radius: 6, tone: .chip) {
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
                        Button {
                            filtersDialogPresented = true
                        } label: {
                            TahoeIcon("sliders", size: 13)
                                .foregroundStyle(filtersAreActive ? t.accent : t.fg3)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 38)
                }
                .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 10)

                // Desktop parity: a visible four-bucket status model
                // (Active / Review / Done / Archived) with a summary
                // "All" scope, rather than hiding status state entirely
                // behind the filter menu.
                statusBuckets
                    .padding(.bottom, 16)

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
                            agentClient: agentClient,
                            outbox: outbox,
                            presentationStore: presentationStore
                        )
                        }
                    }
                    .padding(.horizontal, 16).padding(.bottom, 30)
                }
            }
        }
        .confirmationDialog("Filter sessions", isPresented: $filtersDialogPresented, titleVisibility: .visible) {
            ForEach(StatusScope.allCases) { scope in
                Button("\(scope.label) \(statusCounts[scope] ?? 0)") {
                    statusScope = scope
                    if scope == .archived {
                        includeRecents = true
                    }
                }
            }
            Button(includeRecents ? "Hide recent sessions" : "Show recent sessions") {
                includeRecents.toggle()
                if statusScope == .archived {
                    statusScope = .all
                }
            }
            Button("All providers") {
                providerFilter = nil
            }
            ForEach(availableProviders, id: \.id) { provider in
                Button(provider.displayName) {
                    providerFilter = provider
                }
            }
        }
        .sheet(isPresented: $workspaceSwitcherPresented) {
            Group {
                if let agentClient {
                    iOSWorkspaceSwitcherSheet(
                        client: agentClient,
                        onOpenSession: onOpenDetail,
                        onNewSession: onNewSession
                    )
                } else {
                    NavigationStack {
                        ContentUnavailableView(
                            "Workspace switcher unavailable",
                            systemImage: "macbook.and.iphone",
                            description: Text("Pair this iPhone with the Mac daemon to switch real workspaces and sessions.")
                        )
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var filtersAreActive: Bool {
        statusScope != .all || providerFilter != nil || !includeRecents
    }

    private var statusCounts: [StatusScope: Int] {
        let repos = data.repos
        let sessions = repos.flatMap(\.sessions)
        let recents = repos.flatMap(\.recents)
        return [
            .all: sessions.count + (includeRecents ? recents.count : 0),
            .active: sessions.filter { Self.isActive($0) }.count,
            .review: sessions.filter { Self.isInReview($0) }.count,
            .done: sessions.filter { $0.status == .done }.count,
            .archived: recents.count,
        ]
    }

    private var availableProviders: [TahoeProvider] {
        let providers = data.repos.flatMap { repo in
            repo.sessions.map(\.agent) + repo.recents.map(\.provider)
        }
        var seen = Set<String>()
        return providers
            .filter { seen.insert($0.rawValue).inserted }
            .sorted { $0.displayName < $1.displayName }
    }

    private var statusBuckets: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(StatusScope.allCases) { scope in
                    statusBucket(scope)
                }
            }
            .padding(.horizontal, 16)
        }
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.05),
                    .init(color: .black, location: 0.95),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
    }

    private func statusBucket(_ scope: StatusScope) -> some View {
        let selected = statusScope == scope
        let count = statusCounts[scope] ?? 0
        return Button {
            statusScope = scope
            if scope == .archived {
                includeRecents = true
            }
        } label: {
            HStack(spacing: 6) {
                TahoeIcon(scope.icon, size: 12)
                Text(scope.label)
                Text("\(count)")
                    .font(TahoeFont.mono(10.5, weight: .bold))
                    .foregroundStyle(selected ? .white.opacity(0.82) : t.fg4)
            }
            .font(TahoeFont.body(11.5, weight: .bold))
            .foregroundStyle(selected ? .white : t.fg2)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                selected
                    ? LinearGradient(colors: [t.accent, t.accentDeepC], startPoint: .top, endPoint: .bottom)
                    : LinearGradient(colors: [t.glassTintHi, t.glassTintHi], startPoint: .top, endPoint: .bottom),
                in: Capsule(style: .continuous)
            )
            .overlay {
                Capsule(style: .continuous)
                    .stroke(selected ? Color.clear : t.hairline, lineWidth: 0.5)
            }
        }
        .buttonStyle(.plain)
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            Menu {
                Button {
                    providerFilter = nil
                } label: {
                    Label("All providers", systemImage: providerFilter == nil ? "checkmark" : "circle")
                }
                ForEach(availableProviders, id: \.id) { provider in
                    Button {
                        providerFilter = provider
                    } label: {
                        Label(provider.displayName, systemImage: providerFilter?.rawValue == provider.rawValue ? "checkmark" : "circle")
                    }
                }
            } label: {
                filterChip(
                    icon: "sliders",
                    text: providerFilter?.displayName ?? "All providers",
                    active: providerFilter != nil
                )
            }
            Toggle(isOn: $includeRecents) {
                filterChip(icon: "archive", text: "Recent", active: includeRecents)
            }
            .toggleStyle(.button)
            .buttonStyle(.plain)
            Spacer(minLength: 0)
        }
    }

    private func filterChip(icon: String, text: String, active: Bool) -> some View {
        HStack(spacing: 6) {
            TahoeIcon(icon, size: 11)
            Text(text)
                .lineLimit(1)
        }
        .font(TahoeFont.body(11.5, weight: .semibold))
        .foregroundStyle(active ? t.fg : t.fg3)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(active ? t.glassTintHi : t.glassTint, in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous).stroke(t.hairline, lineWidth: 0.5)
        }
    }

    /// PR #26 D5: filter repos + sessions by `searchQuery`. Empty query
    /// is identical to today's behavior (regression-safe).
    private var filteredRepos: [TahoeCodeRepo] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let baseline = data.repos.compactMap { repo -> TahoeCodeRepo? in
            var sessions = repo.sessions
            var recents = includeRecents ? repo.recents : []
            if let providerFilter {
                sessions = sessions.filter { $0.agent == providerFilter }
                recents = recents.filter { $0.provider == providerFilter }
            }
            switch statusScope {
            case .all:
                break
            case .active:
                sessions = sessions.filter { Self.isActive($0) }
                recents = []
            case .review:
                sessions = sessions.filter { Self.isInReview($0) }
                recents = []
            case .done:
                sessions = sessions.filter { $0.status == .done }
                recents = []
            case .archived:
                sessions = []
            }
            guard !sessions.isEmpty || !recents.isEmpty else { return nil }
            return TahoeCodeRepo(
                key: repo.key,
                name: repo.name,
                tint: repo.tint,
                liveSessionCount: sessions.filter { $0.status == .running || $0.status == .planning }.count,
                sessions: sessions,
                recents: recents
            )
        }
        let collapsedBaseline = TahoeCodeProjectList.collapseDuplicateVisibleNames(baseline)
        guard !query.isEmpty else { return collapsedBaseline }
        let matched: [TahoeCodeRepo] = collapsedBaseline.compactMap { repo in
            let matchedSessions = repo.sessions.filter { s in
                s.title.lowercased().contains(query)
            }
            let matchedRecents = repo.recents.filter { r in
                r.title.lowercased().contains(query)
            }
            // Also match the repo name itself — typing "ccwatch" should
            // surface that repo even if no session title matches.
            let repoMatches = repo.name.lowercased().contains(query)
            if matchedSessions.isEmpty && matchedRecents.isEmpty && !repoMatches { return nil }
            return TahoeCodeRepo(
                key: repo.key,
                name: repo.name,
                tint: repo.tint,
                liveSessionCount: (repoMatches ? repo.sessions : matchedSessions)
                    .filter { $0.status == .running || $0.status == .planning }.count,
                sessions: repoMatches ? repo.sessions : matchedSessions,
                recents: repoMatches ? repo.recents : matchedRecents
            )
        }
        return TahoeCodeProjectList.collapseDuplicateVisibleNames(matched)
    }

    private static func isActive(_ session: TahoeCodeSession) -> Bool {
        switch session.status {
        case .running, .paused, .degraded:
            return true
        case .planning, .done:
            return false
        }
    }

    private static func isInReview(_ session: TahoeCodeSession) -> Bool {
        if session.status == .planning { return true }
        if let plan = session.runtimePlanText?.trimmingCharacters(in: .whitespacesAndNewlines), !plan.isEmpty {
            return true
        }
        return false
    }
}

private struct IOSDesktopSyncBadge: View {
    @Environment(\.tahoe) private var t
    @ObservedObject var client: AgentControlClient
    var onPair: () -> Void

    var body: some View {
        let connected = client.isDesktopEventSyncConnected
        Button(action: onPair) {
            HStack(spacing: 6) {
                Circle()
                    .fill(connected ? Color.green : (client.isConfigured ? Color.orange : t.fg4))
                    .frame(width: 7, height: 7)
                Text(label)
                    .font(TahoeFont.body(11, weight: .semibold))
                    .foregroundStyle(connected ? t.fg2 : t.fg3)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background {
                Capsule(style: .continuous)
                    .fill(t.dark ? Color.white.opacity(0.07) : Color.white.opacity(0.82))
                    .overlay {
                        Capsule(style: .continuous)
                            .stroke(t.hairline, lineWidth: 0.6)
                    }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityHint("Opens desktop pairing.")
    }

    private var label: String {
        if client.isDesktopEventSyncConnected { return "Desktop live" }
        if client.isConfigured { return "Reconnecting" }
        return "Not paired"
    }
}

private struct IOSRepoCard: View {
    @Environment(\.tahoe) private var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var repo: TahoeCodeRepo
    var onOpen: (UUID) -> Void
    /// PR #35: daemon client used by the recent-row tap handler to
    /// call `unarchiveSession(id:)`. Nil keeps the row read-only.
    var agentClient: AgentControlClient?
    var outbox: MobileCommandOutbox?
    @ObservedObject var presentationStore: SessionPresentationStore
    @State private var restoringSessionId: UUID? = nil

    private var repoBadge: RepoIdentityBadge {
        if let cached = presentationStore.snapshot.repoIdentityBadges[repo.key] {
            return cached
        }
        return RepoIdentityResolver.badge(repoKey: repo.key, displayName: repo.name)
    }

    var body: some View {
        TahoeGlass(radius: 8, tone: .raised) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    RepoIdentityBadgeView(badge: repoBadge, size: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(repo.name)
                            .font(TahoeFont.body(13.5, weight: .bold))
                            .foregroundStyle(t.fg)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("\(repo.sessions.count) active · \(repo.recents.count) recent")
                            .font(TahoeFont.body(11))
                            .foregroundStyle(t.fg4)
                            .lineLimit(1)
                    }
                    Spacer()
                    if repo.liveSessionCount > 0 {
                        Text("\(repo.liveSessionCount)")
                            .font(TahoeFont.mono(11, weight: .bold))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 7)
                            .frame(height: 22)
                            .background(Color.green.opacity(0.14), in: Capsule(style: .continuous))
                            .accessibilityLabel("\(repo.liveSessionCount) live sessions")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)
                TahoeHair().padding(.leading, 58)
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
                                    .truncationMode(.middle)
                                HStack(spacing: 6) {
                                    StatusDot(status: s.status)
                                    Text(s.subtitle)
                                        .font(TahoeFont.body(11.5))
                                        .foregroundStyle(t.fg3)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }
                                if let progress = s.planProgress {
                                    // Defensive clamp (see Mac sessionRow comment).
                                    let safeCompleted = max(0, min(progress.completed, progress.total))
                                    let isComplete = safeCompleted >= progress.total && progress.total > 0
                                    // Use provider.halo so dark-mode + low-luminance
                                    // providers (Codex / Cursor) stay legible against
                                    // the popover background. provider.deep collapses
                                    // to near-black for those, which is invisible.
                                    let completeTint = s.agent.halo.color
                                    HStack(spacing: 6) {
                                        TahoePillBar(
                                            percent: Double(safeCompleted) /
                                                      max(1, Double(progress.total)) * 100,
                                            provider: s.agent,
                                            height: 6
                                        )
                                        .frame(maxWidth: .infinity)
                                        if isComplete {
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.system(size: 11, weight: .bold))
                                                .foregroundStyle(completeTint)
                                                .padding(.leading, 2)
                                                .transition(.scale.combined(with: .opacity))
                                                .accessibilityHidden(true)
                                        }
                                        Text("\(safeCompleted)/\(progress.total)")
                                            .font(TahoeFont.body(11.5, weight: isComplete ? .bold : .semibold))
                                            .monospacedDigit()
                                            .foregroundStyle(isComplete ? completeTint : t.fg2)
                                            .frame(minWidth: 48, alignment: .trailing)
                                            .contentTransition(reduceMotion ? .identity : .numericText())
                                    }
                                    .padding(.top, 4)
                                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: isComplete)
                                    .accessibilityElement(children: .combine)
                                    .accessibilityLabel("Plan progress")
                                    .accessibilityValue("\(safeCompleted) of \(progress.total) steps complete")
                                    .accessibilityHint(isComplete ? "Plan complete" : "")
                                }
                                statusBadges(for: s)
                            }
                            .layoutPriority(1)
                            Spacer(minLength: 8)
                            TahoeIcon("chevR", size: 14).foregroundStyle(t.fg4)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 14)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Open Session", systemImage: "arrow.right") { onOpen(s.id) }
                        Button(presentationStore.snapshot.pinnedSessionIds.contains(s.id) ? "Unpin" : "Pin", systemImage: "pin") {
                            try? presentationStore.togglePin(s.id)
                        }
                        Button(presentationStore.snapshot.unreadSessionIds.contains(s.id) ? "Mark Read" : "Mark Unread", systemImage: "circle.fill") {
                            try? presentationStore.markUnread(s.id, unread: !presentationStore.snapshot.unreadSessionIds.contains(s.id))
                        }
                        Button(presentationStore.snapshot.mutedSessionIds.contains(s.id) ? "Unmute" : "Mute", systemImage: "bell.slash") {
                            try? presentationStore.setMuted(s.id, muted: !presentationStore.snapshot.mutedSessionIds.contains(s.id))
                        }
                        Button("Copy Session ID", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = s.id.uuidString
                        }
                    }
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

    @ViewBuilder
    private func statusBadges(for session: TahoeCodeSession) -> some View {
        let items = statusBadgeItems(for: session)
        if !items.isEmpty {
            HStack(spacing: 5) {
                ForEach(items.prefix(3)) { item in
                    smallBadge(item.text, icon: item.icon, tone: item.tone)
                }
                if items.count > 3 {
                    smallBadge("+\(items.count - 3)", icon: "ellipsis", tone: t.fg3)
                        .accessibilityLabel("More session states: \(items.dropFirst(3).map(\.text).joined(separator: ", "))")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 3)
        }
    }

    private func statusBadgeItems(for session: TahoeCodeSession) -> [IOSSessionBadgeItem] {
        var items: [IOSSessionBadgeItem] = []
        let pending = outbox?.pending.filter { $0.sessionId == session.id }.count ?? 0
        let failed = outbox?.failed.filter { $0.sessionId == session.id }.count ?? 0
        if presentationStore.snapshot.pinnedSessionIds.contains(session.id) {
            items.append(.init(text: "Pin", icon: "pin", tone: t.accent))
        }
        if presentationStore.snapshot.unreadSessionIds.contains(session.id) {
            items.append(.init(text: "New", icon: "circle", tone: .blue))
        }
        if presentationStore.snapshot.mutedSessionIds.contains(session.id) {
            items.append(.init(text: "Mute", icon: "bellSlash", tone: t.fg4))
        }
        if session.status == .planning {
            items.append(.init(text: "Plan", icon: "sparkles", tone: t.accent))
        }
        if pending > 0 {
            items.append(.init(text: "\(pending)", icon: "arrowU", tone: t.fg3))
        }
        if failed > 0 {
            items.append(.init(text: "\(failed)", icon: "x", tone: .red))
        }
        return items
    }

    private func smallBadge(_ text: String, icon: String, tone: Color) -> some View {
        HStack(spacing: 3) {
            TahoeIcon(icon, size: 9)
            Text(text)
                .font(TahoeFont.mono(10, weight: .bold))
        }
        .foregroundStyle(tone)
        .padding(.horizontal, 6)
        .frame(height: 20)
        .background(tone.opacity(0.14), in: Capsule(style: .continuous))
    }
}

private struct IOSSessionBadgeItem: Identifiable {
    let text: String
    let icon: String
    let tone: Color

    var id: String { "\(icon):\(text)" }
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

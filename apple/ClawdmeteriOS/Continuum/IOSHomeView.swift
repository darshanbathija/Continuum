import SwiftUI
import ClawdmeterShared

/// Continuum Mobile Home — command center over live daemon sessions.
public struct IOSHomeView: View {
    @Environment(\.theme) private var theme
    @ObservedObject var agentClient: AgentControlClient
    var onOpenSession: (UUID) -> Void
    var onNewSession: () -> Void
    var onOpenSettings: () -> Void

    @State private var homeFilter: HomeFilter = .all

    private enum HomeFilter: String {
        case needs, active, all
    }

    public init(
        agentClient: AgentControlClient,
        onOpenSession: @escaping (UUID) -> Void,
        onNewSession: @escaping () -> Void = {},
        onOpenSettings: @escaping () -> Void = {}
    ) {
        self.agentClient = agentClient
        self.onOpenSession = onOpenSession
        self.onNewSession = onNewSession
        self.onOpenSettings = onOpenSettings
    }

    private var liveSessions: [AgentSession] {
        agentClient.sessions
            .filter { $0.archivedAt == nil }
            .sorted { lhs, rhs in
                let lp = IOSContinuumHomeState.from(lhs).priority
                let rp = IOSContinuumHomeState.from(rhs).priority
                if lp != rp { return lp < rp }
                return lhs.lastEventAt > rhs.lastEventAt
            }
    }

    private var actionSessions: [AgentSession] {
        liveSessions.filter { IOSContinuumHomeState.from($0).needsAction }
    }

    private var workingSessions: [AgentSession] {
        liveSessions.filter {
            let s = IOSContinuumHomeState.from($0)
            return !s.needsAction && s != .done && s != .idle
        }
    }

    private var idleSessions: [AgentSession] {
        liveSessions.filter {
            let s = IOSContinuumHomeState.from($0)
            return s == .idle || s == .done
        }
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                if liveSessions.isEmpty {
                    emptyState
                } else {
                    let showNeeds = homeFilter == .all || homeFilter == .needs
                    let showActive = homeFilter == .all || homeFilter == .active
                    let showIdle = homeFilter == .all
                    if showNeeds, !actionSessions.isEmpty {
                        section(title: "NEEDS YOU", count: actionSessions.count, accent: theme.warn) {
                            ForEach(actionSessions) { session in
                                actionCard(session)
                            }
                        }
                    }
                    if showActive, !workingSessions.isEmpty {
                        section(title: "THE MACHINE IS WORKING", count: workingSessions.count) {
                            ForEach(workingSessions) { session in
                                sessionRow(session, dim: false)
                            }
                        }
                    }
                    if showIdle, !idleSessions.isEmpty {
                        section(title: "IDLE", count: idleSessions.count) {
                            ForEach(idleSessions) { session in
                                sessionRow(session, dim: true)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .refreshable { await agentClient.refreshAll() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    ContinuumScreenHeader(title: "Home")
                }
                Spacer()
                Button(action: ContinuumAnalytics.wrapButton("home_new_session", onNewSession)) {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(theme.fg)
                        .frame(width: 38, height: 38)
                        .background(theme.surface2)
                        .clipShape(Circle())
                        .overlay(Circle().strokeBorder(theme.hairline, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                Button(action: ContinuumAnalytics.wrapButton("home_settings", onOpenSettings)) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(theme.fg)
                        .frame(width: 38, height: 38)
                        .background(theme.surface2)
                        .clipShape(Circle())
                        .overlay(Circle().strokeBorder(theme.hairline, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
            }
            filterChips
        }
        .padding(.top, 6)
        .padding(.bottom, 14)
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterChip(
                    label: actionSessions.isEmpty ? "Needs you" : "\(actionSessions.count) need you",
                    active: homeFilter == .needs,
                    accent: theme.warn
                ) { homeFilter = homeFilter == .needs ? .all : .needs }
                filterChip(
                    label: workingSessions.isEmpty ? "Active" : "\(workingSessions.count) active",
                    active: homeFilter == .active,
                    accent: theme.live
                ) { homeFilter = homeFilter == .active ? .all : .active }
                filterChip(
                    label: liveSessions.isEmpty ? "Sessions" : "\(liveSessions.count) sessions",
                    active: homeFilter == .all,
                    accent: theme.fg3
                ) { homeFilter = .all }
            }
            .padding(.vertical, 2)
        }
    }

    private func filterChip(label: String, active: Bool, accent: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(ContinuumFont.body(12, weight: .semibold))
                .foregroundStyle(active ? accent : theme.fg4)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(active ? accent.opacity(0.12) : theme.surface2)
                .clipShape(Capsule(style: .continuous))
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(active ? accent.opacity(0.35) : theme.hairline, lineWidth: 0.5)
                }
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        ContinuumSurface(level: .one, padding: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("No active sessions")
                    .font(ContinuumFont.body(16, weight: .semibold))
                    .foregroundStyle(theme.fg)
                Text("Sessions started on your Mac appear here once you're paired.")
                    .font(ContinuumFont.body(13))
                    .foregroundStyle(theme.fg3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private func section<Content: View>(title: String, count: Int, accent: Color? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                ContinuumEtchedLabel(text: title)
                Text("\(count)")
                    .font(ContinuumFont.mono(11, weight: .semibold))
                    .foregroundStyle(accent ?? theme.fg3)
                Spacer()
            }
            .padding(.horizontal, 1)
            content()
        }
        .padding(.bottom, 22)
    }

    private func actionCard(_ session: AgentSession) -> some View {
        let state = IOSContinuumHomeState.from(session)
        let (done, total) = progress(for: session)
        return ContinuumSurface(level: .two, padding: 15) {
            VStack(alignment: .leading, spacing: 11) {
                IOSContinuumRepoTag(repoName(for: session))
                Text(sessionTitle(for: session))
                    .font(ContinuumFont.body(16, weight: .semibold))
                    .foregroundStyle(theme.fg)
                    .lineLimit(2)
                VStack(alignment: .leading, spacing: 5) {
                    IOSContinuumProviderRow(provider: session.agent.tahoeProvider, model: session.model ?? session.agent.tahoeProvider.displayName)
                    Text(session.workspaceBranchLabel)
                        .font(ContinuumFont.mono(11))
                        .foregroundStyle(theme.fg3)
                        .lineLimit(1)
                }
                VStack(alignment: .leading, spacing: 7) {
                    IOSContinuumSessionProgressRail(
                        provider: session.agent.tahoeProvider,
                        state: state,
                        completed: done,
                        total: total,
                        height: 6
                    )
                    Text(progressNote(session: session, state: state, done: done, total: total))
                        .font(ContinuumFont.mono(11))
                        .foregroundStyle(state == .blocked ? theme.error : theme.fg3)
                        .lineLimit(1)
                }
                HStack(spacing: 9) {
                    Button(action: { onOpenSession(session.id) }) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(theme.fg2)
                            .frame(width: 46, height: 42)
                            .background(theme.surface1)
                            .clipShape(RoundedRectangle(cornerRadius: ContinuumTokens.Radius.button, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: ContinuumTokens.Radius.button, style: .continuous)
                                    .strokeBorder(theme.hairline, lineWidth: 0.5)
                            }
                    }
                    .buttonStyle(.plain)
                    Button(action: { onOpenSession(session.id) }) {
                        Text(actionLabel(for: state))
                            .font(ContinuumFont.body(15, weight: .semibold))
                            .foregroundStyle(state == .blocked ? theme.error : theme.primaryText)
                            .frame(maxWidth: .infinity, minHeight: 42)
                            .background {
                                if state == .blocked {
                                    RoundedRectangle(cornerRadius: ContinuumTokens.Radius.button, style: .continuous)
                                        .strokeBorder(theme.error, lineWidth: 0.5)
                                } else {
                                    RoundedRectangle(cornerRadius: ContinuumTokens.Radius.button, style: .continuous)
                                        .fill(theme.primaryFill)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func sessionRow(_ session: AgentSession, dim: Bool) -> some View {
        let state = IOSContinuumHomeState.from(session)
        let (done, total) = progress(for: session)
        return Button(action: { onOpenSession(session.id) }) {
            ContinuumSurface(level: .one, padding: 13) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 9) {
                        IOSContinuumRepoTag(repoName(for: session), compact: true)
                        Spacer()
                        IOSContinuumStateChip(state: state)
                    }
                    Text(sessionTitle(for: session))
                        .font(ContinuumFont.body(14, weight: .semibold))
                        .foregroundStyle(theme.fg)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 4) {
                        IOSContinuumProviderRow(provider: session.agent.tahoeProvider, model: session.model ?? session.agent.tahoeProvider.displayName)
                        Text(session.workspaceBranchLabel)
                            .font(ContinuumFont.mono(10.5))
                            .foregroundStyle(theme.fg3)
                            .lineLimit(1)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        IOSContinuumSessionProgressRail(
                            provider: session.agent.tahoeProvider,
                            state: state,
                            completed: done,
                            total: total,
                            height: 5
                        )
                        Text(progressNote(session: session, state: state, done: done, total: total))
                            .font(ContinuumFont.mono(10.5))
                            .foregroundStyle(theme.fg3)
                            .lineLimit(1)
                    }
                }
            }
            .opacity(dim ? 0.62 : 1)
        }
        .buttonStyle(.plain)
    }

    private func repoName(for session: AgentSession) -> String {
        if let key = session.repoKey {
            return URL(fileURLWithPath: key).lastPathComponent
        }
        return session.repoDisplayName
    }

    private func sessionTitle(for session: AgentSession) -> String {
        if let goal = session.goal?.trimmingCharacters(in: .whitespacesAndNewlines), !goal.isEmpty {
            return goal
        }
        return session.displayLabel
    }

    private func progress(for session: AgentSession) -> (Int, Int) {
        if let p = session.planProgress {
            return (p.completed, p.total)
        }
        let plan = session.approvedPlanText ?? session.planText
        if let plan, !plan.isEmpty {
            let steps = ChatMessageOrdering.extractStepCandidates(from: plan)
            if !steps.isEmpty {
                return (0, steps.count)
            }
        }
        return (0, 0)
    }

    private func progressNote(session: AgentSession, state: IOSContinuumHomeState, done: Int, total: Int) -> String {
        switch state {
        case .planning:
            return "drafting a plan…"
        case .needsApproval:
            return total > 0 ? "\(total)-step plan ready" : "plan ready for approval"
        case .executing:
            if total > 0 {
                return "step \(min(done + 1, total))/\(total)"
            }
            return "executing · \(TahoeFmt.ago(from: session.lastEventAt))"
        case .review:
            if let pr = session.prMirrorState?.number {
                return "PR #\(pr) · review"
            }
            return "ready for review"
        case .blocked:
            if total > 0 { return "stopped at \(done)/\(total)" }
            return session.status == .degraded ? "degraded · needs recovery" : "blocked"
        case .done:
            return "merged · \(TahoeFmt.ago(from: session.lastEventAt))"
        case .idle:
            return "idle · \(TahoeFmt.ago(from: session.lastEventAt))"
        }
    }

    private func actionLabel(for state: IOSContinuumHomeState) -> String {
        switch state {
        case .needsApproval: return "Approve & run"
        case .review: return "Review & merge"
        case .blocked: return "Resolve"
        default: return "Open"
        }
    }
}

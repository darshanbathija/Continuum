import SwiftUI
import ClawdmeterShared

/// Mac Code IDE — sidebar + thread/composer + review pane. Ports
/// `mac-sessions.jsx` + `mac-sessions-parts.jsx` + `mac-composer.jsx`.
/// Accepts a `TahoeCodeBindings` value (defaults to demo); the Mac app
/// injects real AgentRuntime-derived data via `MacRootView.body`.
///
/// Codex review P1 fix: every demo-content surface (thread, plan halo,
/// review pane tabs) is now gated on `data.isDemo`. In production
/// (`data.isDemo == false`) the IDE renders empty-state placeholders
/// rather than the JSX fixture data — so a user can't approve a fake
/// plan or read a hardcoded diff thinking it's their real session.
public struct MacCodeView: View {
    @Environment(\.tahoe) private var t

    public enum ComposerState: String { case idle, running, plan }
    public enum ReviewTab: String, CaseIterable { case plan, diff, sources, pr, term }

    public var data: TahoeCodeBindings
    /// Caller-provided callbacks. `onNewSession(key)` is fired by the
    /// per-repo `+` button (key = repo path) and the sidebar `+` icon
    /// (key = nil, sheet lets user pick). Defaults to `{ _ in }` so the
    /// view remains preview-friendly.
    var onNewSession: (String?) -> Void
    /// Open a PR in the system browser. Wired only when the PR review
    /// tab is visible (i.e. demo bindings today).
    var onOpenPRInBrowser: (() -> Void)?

    @State private var openId: UUID? = nil
    @State private var composerState: ComposerState = .idle
    @State private var rightTab: ReviewTab = .plan
    @State private var showRight: Bool = true
    @State private var expanded: Set<String> = []
    @State private var didInitComposer: Bool = false

    public init(
        data: TahoeCodeBindings = .demo,
        onNewSession: @escaping (String?) -> Void = { _ in },
        onOpenPRInBrowser: (() -> Void)? = nil
    ) {
        self.data = data
        self.onNewSession = onNewSession
        self.onOpenPRInBrowser = onOpenPRInBrowser
    }

    public var body: some View {
        let effectiveOpenId = openId ?? data.openSessionId
        let openRepo = data.repos.first { repo in
            repo.sessions.contains { $0.id == effectiveOpenId }
        } ?? data.repos.first
        let openSession = openRepo?.sessions.first { $0.id == effectiveOpenId }

        HStack(spacing: 10) {
            TahoeGlass(radius: 20, tone: .panel) {
                Sidebar(
                    repos: data.repos,
                    openId: Binding(get: { effectiveOpenId }, set: { openId = $0 }),
                    expanded: $expanded,
                    onNewSession: onNewSession
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: 260)

            TahoeGlass(radius: 20, tone: .panel) {
                VStack(spacing: 0) {
                    if let openSession {
                        ThreadHeader(session: openSession, isDemo: data.isDemo)
                        TahoeHair()
                    }
                    Thread(session: openSession, state: composerState, isDemo: data.isDemo)
                        .frame(maxHeight: .infinity)
                    ComposerBar(
                        state: $composerState,
                        isDemo: data.isDemo,
                        hasRealPlan: openSession?.runtimePlanText?.isEmpty == false,
                        onCycle: {
                            composerState = composerState == .idle ? .running
                                          : composerState == .running ? .plan
                                          : .idle
                        }
                    )
                }
            }
            .frame(maxWidth: .infinity)

            if showRight {
                TahoeGlass(radius: 20, tone: .panel) {
                    ReviewPane(tab: $rightTab, session: openSession, isDemo: data.isDemo)
                }
                .frame(width: 380)
            }
        }
        .onAppear {
            // Default-expand the first 2 repos so the user sees sessions
            // immediately — matches JSX `useState(['defx-frontend','ccwatch'])`.
            if expanded.isEmpty {
                expanded = Set(data.repos.prefix(2).map { $0.key })
            }
            // Demo bindings start in `.plan` so Xcode Previews show the
            // halo card; production starts in `.idle` so we don't dangle
            // a halo with no underlying plan text.
            if !didInitComposer {
                composerState = data.isDemo ? .plan : .idle
                didInitComposer = true
            }
        }
        .onChange(of: data.repos.flatMap { $0.sessions.map { $0.id } }) { _, ids in
            // Watch the FULL session id set, not just repo keys — sessions
            // can be archived while their repo persists. Keep the open-id
            // valid: if the previously open session vanished, pick the
            // first available one in the first repo with sessions.
            if let oid = openId, !ids.contains(oid) {
                openId = data.repos.first(where: { !$0.sessions.isEmpty })?.sessions.first?.id
            }
            // Auto-expand any repo with live sessions so users see new work
            // without manual clicking.
            for repo in data.repos where repo.liveSessionCount > 0 {
                expanded.insert(repo.key)
            }
        }
        .onChange(of: openSession?.id) { _, _ in
            // Switching to a session with a real plan auto-cycles the
            // composer into plan-mode; otherwise it stays idle so the
            // Refine/Approve actions don't dangle.
            if openSession?.runtimePlanText?.isEmpty == false {
                composerState = .plan
            } else if !data.isDemo {
                composerState = .idle
            }
        }
    }
}

// MARK: - Titlebar pieces

private struct ThreadHeader: View {
    @Environment(\.tahoe) private var t
    var session: TahoeCodeSession
    var isDemo: Bool
    var body: some View {
        HStack(spacing: 12) {
            TahoeProviderGlyph(provider: session.agent, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(TahoeFont.body(15, weight: .bold))
                    .foregroundStyle(t.fg)
                Text("\(session.agent.displayName) · \(session.model) · \(session.mode) mode")
                    .font(TahoeFont.body(11.5))
                    .foregroundStyle(t.fg3)
            }
            Spacer()
            // Branch pill renders real `commitBranch` (worktree sessions)
            // when present; demo bindings keep the JSX placeholder. Local
            // sessions in production omit it rather than display a
            // fake branch name.
            if let branch = session.commitBranch, !branch.isEmpty {
                TahoePill {
                    HStack(spacing: 5) {
                        TahoeIcon("branch", size: 11)
                        Text(branch).font(TahoeFont.mono(11))
                    }
                    .foregroundStyle(t.fg2)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                }
            } else if isDemo {
                TahoePill {
                    HStack(spacing: 5) {
                        TahoeIcon("branch", size: 11)
                        Text("fix/settlement-dedupe").font(TahoeFont.mono(11))
                    }
                    .foregroundStyle(t.fg2)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                }
            }
            // Autopilot status pill is a fixture today; hide outside demo
            // until a real autopilot signal exists for code sessions.
            if isDemo {
                TahoePill {
                    HStack(spacing: 5) {
                        TahoeIcon("bolt", size: 11)
                        Text("autopilot · trusted")
                            .font(TahoeFont.body(11))
                    }
                    .foregroundStyle(t.fg2)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                }
            }
        }
        .padding(.horizontal, 22).padding(.top, 14).padding(.bottom, 10)
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @Environment(\.tahoe) private var t
    var repos: [TahoeCodeRepo]
    @Binding var openId: UUID?
    @Binding var expanded: Set<String>
    var onNewSession: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // search
            HStack(spacing: 8) {
                TahoeIcon("search", size: 13).foregroundStyle(t.fg3)
                Text("Search\u{2026}").font(TahoeFont.body(12.5)).foregroundStyle(t.fg3)
                Spacer()
                Text("\u{2318}K")
                    .font(TahoeFont.body(10.5))
                    .foregroundStyle(t.fg4)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .overlay {
                        RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(t.hairline, lineWidth: 0.5)
                    }
            }
            .padding(.horizontal, 10).frame(height: 30)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(t.dark ? Color(.sRGB, white: 1, opacity: 0.06) : Color(.sRGB, white: 15.0/255, opacity: 0.05))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(t.hairline, lineWidth: 0.5)
            }
            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8)

            // Projects header — `folderPlus` opens NewSessionMacSheet with no
            // repo pre-selected (the sheet's picker shows the full list).
            // Filter is reserved for a future "live only" / "by provider"
            // filter sheet; left as a no-op rather than dropped so the UI
            // alignment matches the JSX.
            HStack(spacing: 4) {
                Text("PROJECTS")
                    .font(TahoeFont.body(11, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(t.fg3)
                Spacer()
                SidebarIconBtn(icon: "filter")
                SidebarIconBtn(icon: "folderPlus", action: { onNewSession(nil) })
            }
            .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 6)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if repos.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("No repositories yet")
                                .font(TahoeFont.body(13, weight: .semibold))
                                .foregroundStyle(t.fg2)
                            Text("Add a scan root in Settings or start a session via the menu bar.")
                                .font(TahoeFont.body(11.5))
                                .foregroundStyle(t.fg3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 14)
                    } else {
                        ForEach(repos) { repo in
                            RepoSection(
                                repo: repo,
                                expanded: expanded.contains(repo.key),
                                onToggle: {
                                    if expanded.contains(repo.key) { expanded.remove(repo.key) }
                                    else { expanded.insert(repo.key) }
                                },
                                openId: openId,
                                onOpen: { openId = $0 },
                                onNewSession: { onNewSession(repo.key) }
                            )
                        }
                    }
                }
                .padding(.horizontal, 6).padding(.bottom, 12)
            }
        }
    }
}

private struct SidebarIconBtn: View {
    @Environment(\.tahoe) private var t
    var icon: String
    var action: () -> Void = {}
    var body: some View {
        Button(action: action) {
            TahoeIcon(icon, size: 13).foregroundStyle(t.fg3).frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
    }
}

private struct RepoSection: View {
    @Environment(\.tahoe) private var t
    var repo: TahoeCodeRepo
    var expanded: Bool
    var onToggle: () -> Void
    var openId: UUID?
    var onOpen: (UUID) -> Void
    var onNewSession: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                TahoeIcon(expanded ? "chevD" : "chevR", size: 11).foregroundStyle(t.fg3)
                TahoeProjectGlyph(name: repo.name, tint: repo.tint, size: 22)
                Text(repo.name)
                    .font(TahoeFont.body(13, weight: .semibold))
                    .foregroundStyle(t.fg)
                    .lineLimit(1)
                if repo.liveSessionCount > 0 {
                    HStack(spacing: 3) {
                        Circle().fill(Color(.sRGB, red: 0x28/255.0, green: 0xC8/255.0, blue: 0x40/255.0))
                            .frame(width: 6, height: 6)
                            .shadow(color: Color(.sRGB, red: 0x28/255.0, green: 0xC8/255.0, blue: 0x40/255.0), radius: 3, x: 0, y: 0)
                        Text("\(repo.liveSessionCount)")
                            .font(TahoeFont.body(10, weight: .bold))
                            .foregroundStyle(Color(.sRGB, red: 0x28/255.0, green: 0xC8/255.0, blue: 0x40/255.0))
                    }
                }
                Spacer()
                if !repo.sessions.isEmpty {
                    Text("\(repo.sessions.count)")
                        .font(TahoeFont.body(10.5, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(t.fg3)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background {
                            Capsule(style: .continuous).fill(t.hair2)
                        }
                }
                Button(action: onNewSession) {
                    TahoeIcon("plus", size: 13).foregroundStyle(t.fg3)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("New session in \(repo.name)")
                .opacity(0.55)
            }
            .padding(.horizontal, 4).padding(.vertical, 7)
            .contentShape(Rectangle())
            .onTapGesture { onToggle() }

            if expanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(repo.sessions) { s in
                        SessionRow(session: s, open: openId == s.id, onClick: { onOpen(s.id) })
                    }
                    if !repo.recents.isEmpty {
                        Text("RECENT")
                            .font(TahoeFont.body(10, weight: .bold))
                            .tracking(0.6)
                            .foregroundStyle(t.fg4)
                            .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 4)
                        ForEach(repo.recents) { r in
                            RecentRow(recent: r)
                        }
                    }
                }
                .padding(.leading, 8)
            }
        }
    }
}

private struct SessionRow: View {
    @Environment(\.tahoe) private var t
    var session: TahoeCodeSession
    var open: Bool
    var onClick: () -> Void

    var body: some View {
        Button(action: onClick) {
            HStack(alignment: .top, spacing: 8) {
                TahoeProviderGlyph(provider: session.agent, size: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title)
                        .font(TahoeFont.body(12, weight: .semibold))
                        .foregroundStyle(t.fg)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        let color = statusColor(session.status)
                        Circle().fill(color).frame(width: 5, height: 5)
                            .shadow(color: session.status == .running ? color : .clear, radius: 3, x: 0, y: 0)
                        Text(session.subtitle)
                            .font(TahoeFont.body(10.5))
                            .foregroundStyle(t.fg3)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background {
                if open {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(t.accentAlpha(t.dark ? 0.18 : 0.12))
                }
            }
            .overlay {
                if open {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(t.accentAlpha(0.35), lineWidth: 0.5)
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.bottom, 2)
    }

    private func statusColor(_ s: TahoeCodeSession.Status) -> Color {
        switch s {
        case .running:  return Color(.sRGB, red: 0x28/255.0, green: 0xC8/255.0, blue: 0x40/255.0)
        case .planning: return t.fg3
        case .paused:   return Color(.sRGB, red: 0xFE/255.0, green: 0xBC/255.0, blue: 0x2E/255.0)
        case .done:     return t.accent
        case .degraded: return Color(.sRGB, red: 1, green: 0x5F/255.0, blue: 0x57/255.0)
        }
    }
}

private struct RecentRow: View {
    @Environment(\.tahoe) private var t
    var recent: TahoeCodeRecent
    var body: some View {
        Button(action: {}) {
            HStack(alignment: .top, spacing: 8) {
                ZStack {
                    TahoeProviderGlyph(provider: recent.provider, size: 18)
                    if recent.live {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color(.sRGB, red: 0x28/255.0, green: 0xC8/255.0, blue: 0x40/255.0), lineWidth: 1.5)
                            .padding(-2)
                    }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(recent.title)
                        .font(TahoeFont.body(11.5))
                        .foregroundStyle(t.fg2)
                        .lineLimit(1)
                    Text("\(recent.provider.displayName) · \(recent.ago)")
                        .font(TahoeFont.body(10))
                        .foregroundStyle(t.fg4)
                }
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .opacity(0.85)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Thread

private struct Thread: View {
    @Environment(\.tahoe) private var t
    var session: TahoeCodeSession?
    var state: MacCodeView.ComposerState
    var isDemo: Bool

    /// Whether the open session has a real plan from the agent. Drives
    /// whether the PlanHalo renders at all in production — empty plan +
    /// `state == .plan` would otherwise dangle a Refine/Approve card with
    /// no underlying plan content.
    private var hasRealPlan: Bool {
        guard let raw = session?.runtimePlanText else { return false }
        return !raw.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if session == nil {
                    EmptyThreadState()
                } else if isDemo {
                    // Demo bindings keep the JSX fixture so Previews remain
                    // visually rich.
                    ForEach(Array(TahoeDemo.thread.enumerated()), id: \.offset) { _, msg in
                        ThreadMsg(msg: msg, providerOverride: session?.agent)
                    }
                } else {
                    // Production: the live message stream isn't piped to
                    // the IDE yet. Render a placeholder instead of
                    // pretending the JSX fixture is real activity.
                    LiveStreamPlaceholder()
                }
                if state == .running { RunningRow(providerOverride: session?.agent, isDemo: isDemo) }
                if state == .plan, (isDemo || hasRealPlan) {
                    PlanHalo(session: session, isDemo: isDemo)
                }
            }
            .padding(.horizontal, 22).padding(.top, 8).padding(.bottom, 18)
        }
    }
}

private struct LiveStreamPlaceholder: View {
    @Environment(\.tahoe) private var t
    var body: some View {
        VStack(alignment: .center, spacing: 8) {
            TahoeIcon("chat", size: 22).foregroundStyle(t.fg4)
            Text("Live transcript coming soon")
                .font(TahoeFont.body(13, weight: .semibold))
                .foregroundStyle(t.fg2)
            Text("Session metadata above is live. The streamed message thread will appear here once the daemon bridge ships.")
                .font(TahoeFont.body(12))
                .foregroundStyle(t.fg3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }
}

private struct EmptyThreadState: View {
    @Environment(\.tahoe) private var t
    var body: some View {
        VStack(alignment: .center, spacing: 8) {
            TahoeIcon("chat", size: 22).foregroundStyle(t.fg4)
            Text("No session selected")
                .font(TahoeFont.body(14, weight: .semibold))
                .foregroundStyle(t.fg2)
            Text("Pick a session from the sidebar, or start a new one in any repo.")
                .font(TahoeFont.body(12))
                .foregroundStyle(t.fg3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

private struct ThreadMsg: View {
    @Environment(\.tahoe) private var t
    var msg: TahoeDemo.DemoThreadMsg
    /// Optional real provider so the demo bubble at least matches the
    /// real session's agent in Previews where mixed-agent threads matter.
    var providerOverride: TahoeProvider?
    var body: some View {
        switch msg {
        case .user(let text):
            // JSX caps user bubble at maxWidth 78% of the parent column.
            // Use a GeometryReader so the cap scales with the actual thread
            // column width instead of the hard 580pt cap from v1.
            GeometryReader { geo in
                HStack {
                    Spacer()
                    TahoeGlass(radius: 20, tone: .raised) {
                        Text(text)
                            .font(TahoeFont.body(13))
                            .foregroundStyle(t.fg)
                            .padding(.horizontal, 16).padding(.vertical, 12)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: geo.size.width * 0.78, alignment: .trailing)
                }
            }
            .frame(minHeight: 44)
            .fixedSize(horizontal: false, vertical: true)
        case .tool(let tool, let target, let detail):
            HStack(alignment: .top, spacing: 10) {
                Spacer().frame(width: 36)
                TahoePill {
                    HStack(spacing: 8) {
                        TahoeIcon(tool == "grep" ? "search" : "doc", size: 11).foregroundStyle(t.fg2)
                        Text(tool).font(TahoeFont.body(11.5, weight: .semibold)).foregroundStyle(t.fg2)
                        Text(target).font(TahoeFont.mono(11)).foregroundStyle(t.fg3)
                        Text("· \(detail)").font(TahoeFont.body(11)).foregroundStyle(t.fg4)
                    }
                    .padding(.horizontal, 11).padding(.vertical, 5)
                }
                Spacer()
            }
        case .assistant(let text):
            HStack(alignment: .top, spacing: 12) {
                TahoeProviderGlyph(provider: providerOverride ?? .claude, size: 26)
                Text(text)
                    .font(TahoeFont.body(14))
                    .foregroundStyle(t.fg)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
                Spacer()
            }
        }
    }
}

private struct RunningRow: View {
    @Environment(\.tahoe) private var t
    var providerOverride: TahoeProvider?
    var isDemo: Bool
    var body: some View {
        HStack(spacing: 12) {
            TahoeProviderGlyph(provider: providerOverride ?? .claude, size: 26)
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(t.accent)
                if isDemo {
                    Text("Editing ")
                        .font(TahoeFont.body(12.5))
                        .foregroundStyle(t.fg2)
                    + Text("settlement-store.ts")
                        .font(TahoeFont.mono(12.5))
                        .foregroundStyle(t.fg)
                } else {
                    Text("Working…")
                        .font(TahoeFont.body(12.5))
                        .foregroundStyle(t.fg2)
                }
            }
            Spacer()
        }
        .padding(.top, 4)
    }
}

// MARK: - Plan Halo

private struct PlanHalo: View {
    @Environment(\.tahoe) private var t
    @State private var auraGlow: Bool = false
    var session: TahoeCodeSession?
    var isDemo: Bool

    /// Parse `session.planText` into discrete plan steps when available.
    /// In demo mode, falls back to the JSX fixture plan; in production,
    /// the parent Thread view already guards on `hasRealPlan` so this
    /// branch shouldn't reach an empty list — but keep the guard as a
    /// belt-and-braces empty array rather than fixture data.
    private var planSteps: [String] {
        if let session,
           let parsed = parsePlanText(for: session),
           !parsed.isEmpty {
            return parsed
        }
        return isDemo ? TahoeDemo.plan : []
    }

    private func parsePlanText(for session: TahoeCodeSession) -> [String]? {
        guard let raw = session.runtimePlanText, !raw.isEmpty else { return nil }
        let lines = TahoePlanParser.steps(from: raw, cap: 8)
        return lines.isEmpty ? nil : lines
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 38, style: .continuous)
                .fill(RadialGradient(
                    colors: [t.accentGlow.color(opacity: t.muted ? 0.10 : 0.30), .clear],
                    center: .init(x: 0.5, y: 0.3),
                    startRadius: 0, endRadius: 600))
                .blur(radius: 8)
                .padding(-28)
                .allowsHitTesting(false)
                // Motion polish: subtle aura breath (4s, ±15% opacity).
                .opacity(auraGlow ? 1.0 : 0.85)
                .animation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true), value: auraGlow)
                .onAppear { auraGlow = true }

            TahoeGlass(radius: 20, tone: .raised) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(LinearGradient(colors: [t.accent, t.accentDeepC],
                                                 startPoint: .top, endPoint: .bottom))
                            .frame(width: 28, height: 28)
                            .overlay {
                                TahoeIcon("sparkles", size: 14).foregroundStyle(.white)
                            }
                            .shadow(color: t.accentDeep.color(opacity: 0.35), radius: 6, x: 0, y: 4)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("PLAN READY · REVIEW BEFORE RUN")
                                .font(TahoeFont.body(11.5, weight: .semibold))
                                .tracking(0.4)
                                .foregroundStyle(t.fg3)
                            Text("\(planSteps.count) step\(planSteps.count == 1 ? "" : "s")")
                                .font(TahoeFont.body(14, weight: .bold))
                                .foregroundStyle(t.fg)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 6)

                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(planSteps.enumerated()), id: \.offset) { i, step in
                            HStack(alignment: .top, spacing: 12) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(t.hair2)
                                    Text("\(i+1)")
                                        .font(TahoeFont.mono(11, weight: .bold))
                                        .foregroundStyle(t.fg2)
                                }
                                .frame(width: 20, height: 20)

                                Text(step)
                                    .font(TahoeFont.body(13))
                                    .foregroundStyle(t.fg)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(.horizontal, 20).padding(.top, 6).padding(.bottom, 14)

                    TahoeHair()

                    HStack(spacing: 8) {
                        TahoeGhostButton(size: .m) {
                            HStack(spacing: 5) {
                                TahoeIcon("chat", size: 11)
                                Text("Refine")
                            }
                        }
                        TahoeGhostButton(size: .m) {
                            Text("Edit plan")
                        }
                        Spacer()
                        // Only show the "Will commit to <branch>" hint when
                        // there's a real commit branch (worktree session) or
                        // we're rendering the demo fixture. Local production
                        // sessions show no hint rather than the JSX literal.
                        if let branch = session?.commitBranch, !branch.isEmpty {
                            HStack(spacing: 4) {
                                TahoeIcon("branch", size: 10)
                                Text("Will commit to ")
                                + Text(branch).font(TahoeFont.mono(11)).foregroundColor(t.fg2)
                            }
                            .font(TahoeFont.body(11))
                            .foregroundStyle(t.fg3)
                        } else if isDemo {
                            HStack(spacing: 4) {
                                TahoeIcon("branch", size: 10)
                                Text("Will commit to ")
                                + Text("fix/settlement-dedupe").font(TahoeFont.mono(11)).foregroundColor(t.fg2)
                            }
                            .font(TahoeFont.body(11))
                            .foregroundStyle(t.fg3)
                        }
                        // Approve & run remains visible but is disabled in
                        // production until the daemon wire for plan-approval
                        // ships — clicking a no-op accent button on top of
                        // real plan text would be a credible-but-fake
                        // approval signal.
                        TahoeAccentButton(size: .m) {
                            HStack(spacing: 8) {
                                Text("Approve & run")
                                Text("\u{21E7}\u{23CE}").opacity(0.7).fontWeight(.regular)
                            }
                        }
                        .opacity(isDemo ? 1.0 : 0.5)
                        .disabled(!isDemo)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)
                }
            }
        }
        .padding(.top, 6)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Composer

private struct ComposerBar: View {
    @Environment(\.tahoe) private var t
    @Binding var state: MacCodeView.ComposerState
    /// Demo bindings keep the JSX literal placeholder text and the
    /// LiveTicker fixture. Production composer shows a neutral prompt and
    /// hides the fake cost-ticker until the real one is wired.
    var isDemo: Bool
    /// Whether the open session has a real plan from the agent. When false
    /// in production, the chip label stays "autopilot" rather than "plan"
    /// since there's nothing to refine.
    var hasRealPlan: Bool
    var onCycle: () -> Void
    @State private var pulse: Bool = false

    var body: some View {
        let running = state == .running
        let planMode = state == .plan

        VStack(spacing: 0) {
            TahoeGlass(radius: 18, tone: .raised) {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(placeholder(running: running, plan: planMode))
                            .font(TahoeFont.body(14))
                            .foregroundStyle(t.fg3)
                            .frame(maxWidth: .infinity, minHeight: 50, alignment: .topLeading)
                            .opacity(running ? 0.55 : 1)
                    }
                    .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 6)

                    HStack(spacing: 6) {
                        TahoeComposerChip(icon: "sparkles", label: "Sonnet 4.5", caret: true)
                        TahoeComposerChip(icon: "bolt", label: planMode ? "plan" : "autopilot", caret: true, tinted: !planMode)
                        TahoeComposerChip(icon: "paperclip")
                        TahoeComposerChip(icon: "code")
                        TahoeComposerChip(icon: "mic")
                        Spacer()
                        if running {
                            LiveTicker(onStop: onCycle, isDemo: isDemo)
                        } else {
                            SendButton(planMode: planMode, action: onCycle)
                        }
                    }
                    .padding(.horizontal, 10).padding(.bottom, 10).padding(.top, 6)
                }
            }
            .overlay {
                if running {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(t.accentAlpha(0.45), lineWidth: 1)
                        .shadow(color: t.accentAlpha(0.30), radius: 11, x: 0, y: 0)
                        // Motion polish: 1.8s pulse on the running-state rim,
                        // matches JSX `@keyframes pulse{0%,100%{opacity:.7}50%{opacity:1}}`.
                        .opacity(pulse ? 1.0 : 0.7)
                        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
                        .onAppear { pulse = true }
                        .onDisappear { pulse = false }
                }
            }
            .animation(.easeInOut(duration: 0.25), value: state)
        }
        .padding(.horizontal, 18).padding(.bottom, 18)
    }

    private func placeholder(running: Bool, plan: Bool) -> String {
        if plan {
            return isDemo
                ? "Refine the plan above… (e.g. \"skip the migration step, just add the test\")"
                : (hasRealPlan ? "Refine the plan above…" : "Ask anything. Use / for skills, @ for files.")
        }
        if running {
            return isDemo
                ? "Editing settlement-store.ts — send a follow-up…"
                : "Working — send a follow-up…"
        }
        return "Ask anything. Use / for skills, @ for files."
    }
}

private struct SendButton: View {
    @Environment(\.tahoe) private var t
    var planMode: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(planMode ? AnyShapeStyle(t.hair2)
                                       : AnyShapeStyle(LinearGradient(colors: [t.accent, t.accentDeepC],
                                                                      startPoint: .top, endPoint: .bottom)))
                TahoeIcon("arrowU", size: 15, weight: .bold)
                    .foregroundStyle(planMode ? t.fg4 : .white)
            }
            .frame(width: 34, height: 34)
            .shadow(color: planMode ? .clear : t.accentDeep.color(opacity: 0.30), radius: 6, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .disabled(planMode)
    }
}

private struct LiveTicker: View {
    @Environment(\.tahoe) private var t
    var onStop: () -> Void
    /// Demo bindings keep the JSX `$0.124 / 2.3k tok/s` fixture. Production
    /// shows a neutral "live" pill until the real cost/tok stream wire ships.
    var isDemo: Bool

    var body: some View {
        Button(action: onStop) {
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(t.dark ? Color.white.opacity(0.92) : Color(.sRGB, red: 21.0/255, green: 23.0/255, blue: 27.0/255))
                    TahoeIcon("stop", size: 9).foregroundStyle(t.dark ? Color(.sRGB, red: 21.0/255, green: 23.0/255, blue: 27.0/255) : .white)
                }
                .frame(width: 26, height: 26)
                .shadow(color: Color.black.opacity(0.2), radius: 2, x: 0, y: 1)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if isDemo {
                            Text("$0.124")
                                .font(TahoeFont.mono(12.5, weight: .bold))
                                .foregroundStyle(t.fg)
                        } else {
                            Text("Stop")
                                .font(TahoeFont.body(12.5, weight: .bold))
                                .foregroundStyle(t.fg)
                        }
                        Text("● live")
                            .font(TahoeFont.body(10.5, weight: .semibold))
                            .foregroundStyle(t.accent)
                    }
                    if isDemo {
                        Text("2.3k tok/s · 14s elapsed")
                            .font(TahoeFont.body(10))
                            .monospacedDigit()
                            .foregroundStyle(t.fg3)
                    } else {
                        Text("session running")
                            .font(TahoeFont.body(10))
                            .foregroundStyle(t.fg3)
                    }
                }
            }
            .padding(.leading, 4).padding(.trailing, 10)
            .frame(height: 34)
            .background {
                Capsule(style: .continuous)
                    .fill(LinearGradient(colors: [t.accentAlpha(0.18), t.accentAlpha(0.10)],
                                         startPoint: .leading, endPoint: .trailing))
            }
            .overlay {
                Capsule(style: .continuous).stroke(t.accentAlpha(0.40), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Review pane

private struct ReviewPane: View {
    @Environment(\.tahoe) private var t
    @Binding var tab: MacCodeView.ReviewTab
    var session: TahoeCodeSession?
    /// Demo bindings expose all five tabs (Plan / Diff / Sources / PR / Term)
    /// since each has rich JSX fixture content. Production hides everything
    /// except Plan until the real diff/PR/term wires ship — otherwise the
    /// pane shows hardcoded fake diffs that a user could approve.
    var isDemo: Bool

    private var visibleTabs: [(MacCodeView.ReviewTab, String, String)] {
        let all: [(MacCodeView.ReviewTab, String, String)] = [
            (.plan, "Plan", "doc"),
            (.diff, "Diff", "diff"),
            (.sources, "Sources", "search"),
            (.pr, "PR", "pull"),
            (.term, "Term", "terminal"),
        ]
        return isDemo ? all : all.filter { $0.0 == .plan }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(visibleTabs, id: \.0) { tb in
                    let active = tab == tb.0
                    Button { tab = tb.0 } label: {
                        HStack(spacing: 5) {
                            TahoeIcon(tb.2, size: 12)
                            Text(tb.1)
                        }
                        .font(TahoeFont.body(11.5, weight: active ? .bold : .semibold))
                        .foregroundStyle(active ? t.fg : t.fg3)
                        .padding(.horizontal, 0)
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .background {
                            if active {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(t.dark ? Color(.sRGB, white: 1, opacity: 0.10) : .white)
                                    .shadow(color: Color.black.opacity(0.10), radius: 1, x: 0, y: 1)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .onAppear {
                // If production starts on a tab that's now hidden, snap to
                // the only available one — Plan.
                if !isDemo && tab != .plan { tab = .plan }
            }
            .onChange(of: isDemo) { _, demo in
                if !demo && tab != .plan { tab = .plan }
            }

            TahoeHair()

            ScrollView {
                Group {
                    switch tab {
                    case .plan:    ReviewPlan(session: session, isDemo: isDemo)
                    case .diff:    if isDemo { ReviewDiff() } else { EmptyView() }
                    case .sources: if isDemo { ReviewSources() } else { EmptyView() }
                    case .pr:      if isDemo { ReviewPR() } else { EmptyView() }
                    case .term:    if isDemo { ReviewTerm() } else { EmptyView() }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct ReviewPlan: View {
    @Environment(\.tahoe) private var t
    var session: TahoeCodeSession?
    var isDemo: Bool

    private var steps: [String] {
        if let raw = session?.runtimePlanText, !raw.isEmpty {
            let parsed = TahoePlanParser.steps(from: raw, cap: 12)
            if !parsed.isEmpty { return parsed }
        }
        // Production with no plan text shows an empty list and a helper
        // message; demo bindings keep the JSX fixture plan.
        return isDemo ? TahoeDemo.plan : []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if steps.isEmpty {
                VStack(alignment: .center, spacing: 8) {
                    TahoeIcon("doc", size: 22).foregroundStyle(t.fg4)
                    Text("No plan yet")
                        .font(TahoeFont.body(13, weight: .semibold))
                        .foregroundStyle(t.fg2)
                    Text("Run an agent in plan mode and the steps will appear here for review.")
                        .font(TahoeFont.body(12))
                        .foregroundStyle(t.fg3)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 280)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                Text("PLAN · \(steps.count) STEPS")
                    .font(TahoeFont.body(11, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(t.fg3)
                    .padding(.bottom, 10)
                ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                    HStack(alignment: .top, spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(i == 0 ? t.accentAlpha(0.18) : t.hair2)
                            Text("\(i+1)")
                                .font(TahoeFont.mono(11, weight: .bold))
                                .foregroundStyle(i == 0 ? t.accent : t.fg2)
                        }
                        .frame(width: 22, height: 22)
                        Text(step)
                            .font(TahoeFont.body(12.5))
                            .foregroundStyle(t.fg)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 10)
                    if i < steps.count - 1 { TahoeHair() }
                }
            }
        }
        .padding(16)
    }
}

private struct ReviewDiff: View {
    @Environment(\.tahoe) private var t

    private struct Line { var type: String; var text: String }
    private let lines: [Line] = [
        Line(type: "meta", text: "apps/web/src/lib/settlement-store.ts"),
        Line(type: "hunk", text: "@@ -47,12 +47,9 @@ export async function writeSettlement(fill: Fill) {"),
        Line(type: "ctx",  text: "  const ts = Date.now();"),
        Line(type: "del",  text: "  const existing = await db.get(`SELECT 1 FROM settlements WHERE fill_id = ?`, fill.id);"),
        Line(type: "del",  text: "  if (existing) return;"),
        Line(type: "del",  text: "  await db.run(`INSERT INTO settlements (fill_id, ts, ...) VALUES (?, ?, ...)`, fill.id, ts);"),
        Line(type: "add",  text: "  await db.run("),
        Line(type: "add",  text: "    `INSERT INTO settlements (fill_id, ts, ...) VALUES (?, ?, ...) ON CONFLICT (fill_id) DO NOTHING`,"),
        Line(type: "add",  text: "    fill.id, ts,"),
        Line(type: "add",  text: "  );"),
        Line(type: "ctx",  text: "}"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, ln in
                HStack(spacing: 0) {
                    let sign: String = {
                        switch ln.type { case "add": return "+"; case "del": return "-"; case "ctx": return " "; default: return "" }
                    }()
                    if ln.type != "meta" && ln.type != "hunk" {
                        Text(sign)
                            .frame(width: 14, alignment: .leading)
                            .opacity(0.7)
                    }
                    Text(ln.text)
                }
                .font(TahoeFont.mono(11.5))
                .foregroundStyle(color(for: ln.type))
                .padding(.horizontal, 16).padding(.vertical, 1)
                .background(bg(for: ln.type))
            }
        }
    }

    private func color(for type: String) -> Color {
        switch type {
        case "add":  return t.dark ? Color(.sRGB, red: 0x7E/255.0, green: 0xE2/255.0, blue: 0x9A/255.0) : Color(.sRGB, red: 0x1F/255.0, green: 0x7C/255.0, blue: 0x3A/255.0)
        case "del":  return t.dark ? Color(.sRGB, red: 1, green: 0x8E/255.0, blue: 0x88/255.0) : Color(.sRGB, red: 0xA4/255.0, green: 0x23/255.0, blue: 0x2A/255.0)
        case "ctx":  return t.fg2
        case "meta": return t.fg3
        case "hunk": return t.fg3
        default:     return t.fg
        }
    }

    private func bg(for type: String) -> Color {
        switch type {
        case "add":  return t.dark ? Color(.sRGB, red: 56.0/255, green: 180.0/255, blue: 113.0/255, opacity: 0.16) : Color(.sRGB, red: 46.0/255, green: 160.0/255, blue: 67.0/255, opacity: 0.10)
        case "del":  return t.dark ? Color(.sRGB, red: 255.0/255, green: 95.0/255, blue: 87.0/255, opacity: 0.16)  : Color(.sRGB, red: 244.0/255, green: 71.0/255, blue: 71.0/255, opacity: 0.10)
        case "hunk": return t.hair2
        default:     return .clear
        }
    }
}

private struct ReviewSources: View {
    @Environment(\.tahoe) private var t
    private let sources: [(String, String, String)] = [
        ("apps/web/src/lib/settlement-store.ts", "47-72",  "core writeSettlement function"),
        ("apps/web/src/lib/settlement-store.ts", "101-118","reconcileTick re-entry"),
        ("apps/web/src/db/schema.sql",            "34-39", "settlements table definition"),
        ("apps/daemon/src/dedupe-cache.ts",       "12-44", "in-memory dedupe cache used per-process"),
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(sources.enumerated()), id: \.offset) { _, s in
                HStack(alignment: .top, spacing: 10) {
                    TahoeIcon("doc", size: 13).foregroundStyle(t.accent).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(s.0).font(TahoeFont.mono(11.5)).foregroundStyle(t.fg)
                            Text(s.1).font(TahoeFont.body(11.5, weight: .medium)).foregroundStyle(t.fg3)
                        }
                        Text(s.2).font(TahoeFont.body(11)).foregroundStyle(t.fg3)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 10)
            }
        }
        .padding(12)
    }
}

private struct ReviewPR: View {
    @Environment(\.tahoe) private var t

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("fix(settlement): dedupe on insert with ON CONFLICT")
                .font(TahoeFont.body(13, weight: .bold))
                .foregroundStyle(t.fg)
                .padding(.bottom, 4)
            Text("defx-frontend · fix/settlement-dedupe → main")
                .font(TahoeFont.mono(11.5))
                .foregroundStyle(t.fg3)
                .padding(.bottom, 14)

            TahoeGlass(radius: 12, tone: .chip) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Checks").font(TahoeFont.body(11)).foregroundStyle(t.fg3).padding(.bottom, 6)
                    check("unit · settlement", "passed", "14.2s")
                    check("e2e · trading flows", "passed", "2m 18s")
                    check("lint · pnpm", "passed", "6s")
                    check("type-check", "in progress", "\u{2014}")
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.bottom, 10)

            TahoeAccentButton(size: .m) {
                HStack(spacing: 6) {
                    TahoeIcon("pull", size: 12)
                    Text("Open PR on GitHub")
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(16)
    }

    @ViewBuilder
    private func check(_ name: String, _ status: String, _ time: String) -> some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().fill(status == "passed" ? Color(.sRGB, red: 0x28/255.0, green: 0xC8/255.0, blue: 0x40/255.0)
                                                : Color(.sRGB, red: 0xFE/255.0, green: 0xBC/255.0, blue: 0x2E/255.0))
                    .frame(width: 14, height: 14)
                if status == "passed" {
                    TahoeIcon("check", size: 9, weight: .bold).foregroundStyle(.white)
                }
            }
            .shadow(color: status == "in progress" ? Color(.sRGB, red: 0xFE/255.0, green: 0xBC/255.0, blue: 0x2E/255.0) : .clear, radius: 4, x: 0, y: 0)
            Text(name).font(TahoeFont.body(12)).foregroundStyle(t.fg)
            Spacer()
            Text(time).font(TahoeFont.mono(11)).foregroundStyle(t.fg3)
        }
        .padding(.vertical, 4)
    }
}

private struct ReviewTerm: View {
    @Environment(\.tahoe) private var t

    private struct Line { var color: Color; var text: String }
    private var lines: [Line] {
        [
            Line(color: t.fg3, text: "$ pnpm test --filter @defx/settlement"),
            Line(color: t.fg2, text: " PASS  src/settlement-store.test.ts"),
            Line(color: t.fg2, text: "   ✓ writes once when called concurrently (212ms)"),
            Line(color: t.fg2, text: "   ✓ skips on duplicate fill_id (3ms)"),
            Line(color: Color(.sRGB, red: 0x28/255.0, green: 0xC8/255.0, blue: 0x40/255.0), text: "Tests: 14 passed, 14 total"),
            Line(color: t.fg2, text: "Time:  4.182s"),
            Line(color: t.fg3, text: "$ _"),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                Text(l.text)
                    .font(TahoeFont.mono(11.5))
                    .foregroundStyle(l.color)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(t.dark ? Color.black.opacity(0.3) : Color(.sRGB, white: 15.0/255, opacity: 0.04))
    }
}

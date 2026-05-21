import Foundation
import ClawdmeterShared

/// Adapters from the existing AppRuntime data layer to the portable
/// `TahoeLiveBindings` value type that the Tahoe SwiftUI views consume.
///
/// Keeps the views in `ClawdmeterShared/Tahoe/` free of any AppRuntime
/// import — they continue to render the demo fixture in Previews, while
/// `MacRootView.body` calls `runtime.tahoeLive` at render time to feed
/// real `UsageData` snapshots in.
@MainActor
extension AppRuntime {
    /// Compose live bindings from the three per-provider AppModels. Each
    /// `.usage` is optional (poller hasn't returned yet); we fall back to a
    /// demo row in that case so the layout doesn't collapse with empty
    /// strings.
    var tahoeLive: TahoeLiveBindings {
        TahoeLiveBindings(
            claude: tahoeRow(model: claudeModel, provider: .claude),
            codex:  tahoeRow(model: codexModel,  provider: .codex),
            gemini: tahoeRow(model: geminiModel, provider: .gemini)
        )
    }

    private func tahoeRow(model: AppModel, provider: TahoeProvider) -> TahoeLiveRow {
        guard let usage = model.usage else { return .demo(provider) }
        let modelName: String = {
            if provider == .gemini, let m = usage.antigravityModel, !m.isEmpty {
                return m
            }
            return model.config.reviveModel.isEmpty ? provider.displayName : model.config.reviveModel
        }()
        return TahoeLiveRow(
            sessionPercent: Double(usage.sessionPct),
            weeklyPercent: model.config.hasWeeklyWindow ? Double(usage.weeklyPct) : -1,
            sessionResetIn: TahoeFmt.resetIn(minutes: usage.sessionResetMins),
            weeklyResetIn: model.config.hasWeeklyWindow ? TahoeFmt.resetIn(minutes: usage.weeklyResetMins) : "",
            modelName: modelName,
            autoReviveOn: model.config.supportsAutoRevive ? model.autoReviver.isEnabled : false,
            autoReviveAgo: model.config.supportsAutoRevive
                ? TahoeFmt.ago(from: nil) // AutoReviver doesn't currently surface lastFiredAt;
                                          // when added, plumb here.
                : "",
            hasWeekly: model.config.hasWeeklyWindow
        )
    }

    /// Lower the real SessionsModel + AgentSessionRegistry data into the
    /// portable `TahoeCodeBindings` shape that `MacCodeView` consumes.
    /// Falls back to demo fixture when there's nothing live yet.
    var tahoeCode: TahoeCodeBindings {
        let repos = sessionsModel.repos
        guard !repos.isEmpty else { return .demo }
        let liveSessions = agentSessionRegistry.sessions.filter { $0.archivedAt == nil }
        let nowDate = Date()

        let mappedRepos: [TahoeCodeRepo] = repos.map { repo in
            let sessions = liveSessions
                .filter { ($0.repoKey ?? "") == repo.key }
                .sorted { $0.lastEventAt > $1.lastEventAt }
                .map { tahoeSession($0, now: nowDate) }
            let recents: [TahoeCodeRecent] = repo.recentSessions.prefix(4).map { r in
                TahoeCodeRecent(
                    id: r.path,
                    title: r.customName ?? r.firstPrompt ?? URL(fileURLWithPath: r.path).lastPathComponent,
                    provider: mapAgent(r.provider),
                    live: nowDate.timeIntervalSince(r.lastModified) < 5 * 60,
                    ago: TahoeFmt.ago(from: r.lastModified, reference: nowDate)
                )
            }
            return TahoeCodeRepo(
                key: repo.key,
                name: repo.displayName,
                tint: repoTint(forKey: repo.key),
                liveSessionCount: repo.liveSessionCount,
                sessions: sessions,
                recents: recents
            )
        }
        // Pick the first session in the first repo with sessions as the
        // initial open id — matches the demo fixture's default.
        let firstOpen = mappedRepos.first(where: { !$0.sessions.isEmpty })?.sessions.first?.id
        return TahoeCodeBindings(repos: mappedRepos, openSessionId: firstOpen)
    }

    private func tahoeSession(_ s: AgentSession, now: Date) -> TahoeCodeSession {
        let title = s.customName ?? s.goal ?? s.repoDisplayName
        let mode: String = (s.status == .planning) ? "plan" : (s.mode == .worktree ? "worktree" : "local")
        let agoText = TahoeFmt.ago(from: s.lastEventAt, reference: now)
        let subtitle: String = {
            switch s.status {
            case .planning: return "planning \u{00B7} \(agoText)"
            case .running:  return "running \u{00B7} \(agoText)"
            case .paused:   return "paused \u{00B7} \(agoText)"
            case .done:     return "done \u{00B7} \(agoText)"
            case .degraded: return "degraded \u{00B7} \(agoText)"
            }
        }()
        // Derive a friendly commit branch label from worktree path. Real
        // worktrees use `.claude/worktrees/<slug>` so the slug becomes the
        // branch label; local sessions get nil so the halo card omits it.
        let branch: String? = {
            guard let p = s.worktreePath else { return nil }
            let slug = URL(fileURLWithPath: p).lastPathComponent
            return slug.isEmpty ? nil : slug
        }()
        return TahoeCodeSession(
            id: s.id,
            title: title.isEmpty ? "Untitled session" : title,
            agent: mapAgent(s.agent),
            model: s.model ?? mapAgent(s.agent).displayName,
            status: mapStatus(s.status),
            mode: mode,
            subtitle: subtitle,
            runtimePlanText: s.planText,
            commitBranch: branch
        )
    }

    private func mapAgent(_ k: AgentKind) -> TahoeProvider {
        switch k {
        case .claude: return .claude
        case .codex:  return .codex
        case .gemini: return .gemini
        }
    }

    private func mapStatus(_ s: AgentSessionStatus) -> TahoeCodeSession.Status {
        switch s {
        case .planning: return .planning
        case .running:  return .running
        case .paused:   return .paused
        case .done:     return .done
        case .degraded: return .degraded
        }
    }

    /// Stable hue per-repo so tints don't reshuffle between launches.
    /// `key` is a path string — fold it to a deterministic hue 0..360.
    private func repoTint(forKey key: String) -> OKLCH {
        var h: UInt32 = 5381
        for b in key.utf8 { h = (h &* 33) &+ UInt32(b) }
        let hue = Double(h % 360)
        return OKLCH(l: 0.72, c: 0.16, h: hue)
    }
}
